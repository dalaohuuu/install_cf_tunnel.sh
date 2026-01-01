#!/usr/bin/env bash
set -euo pipefail

# ============= 可调默认值 =============
: "${INSTALL_MODE:=bin}"   # bin | deb
: "${CLOUDFLARED_BIN:=/usr/local/bin/cloudflared}"
# ===================================

if [ "${EUID}" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行。"
  exit 1
fi

if [ $# -lt 2 ]; then
  echo "用法：$0 <域名> <本地端口> [Tunnel名]"
  echo "示例：$0 app.example.com 8000"
  exit 1
fi

PUBLIC_HOST="$1"
LOCAL_PORT="$2"
HOSTNAME_SYS="$(hostname)"
TUNNEL_NAME="${3:-${HOSTNAME_SYS}-web}"
LOCAL_HOST="127.0.0.1"
SERVICE_URL="http://${LOCAL_HOST}:${LOCAL_PORT}"

CLOUDFLARED_DIR="/root/.cloudflared"
CONFIG_FILE="${CLOUDFLARED_DIR}/config.yml"
SERVICE_FILE="/etc/systemd/system/cloudflared.service"

echo "==============================================="
echo " 域名            : ${PUBLIC_HOST}"
echo " 本地服务        : ${SERVICE_URL}"
echo " Tunnel 名称     : ${TUNNEL_NAME}"
echo " 安装模式        : ${INSTALL_MODE}"
echo "==============================================="
echo

install_cloudflared_bin() {
  echo "安装 cloudflared（单文件二进制）..."
  mkdir -p "$(dirname "${CLOUDFLARED_BIN}")"
  curl -L --fail -o "${CLOUDFLARED_BIN}" \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "${CLOUDFLARED_BIN}"
}

install_cloudflared_deb() {
  echo "安装 cloudflared（.deb 包）..."
  apt update
  apt install -y wget
  wget -O /tmp/cloudflared-linux-amd64.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  apt install -y /tmp/cloudflared-linux-amd64.deb
  rm -f /tmp/cloudflared-linux-amd64.deb
}

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    echo "检测到 cloudflared：$(command -v cloudflared)"
    return
  fi

  case "${INSTALL_MODE}" in
    bin) install_cloudflared_bin ;;
    deb) install_cloudflared_deb ;;
    *)
      echo "INSTALL_MODE 必须是 bin 或 deb"
      exit 1
      ;;
  esac
}

echo "== [1/6] 确保 cloudflared 已安装 =="
ensure_cloudflared
cloudflared --version || true
echo

echo "== [2/6] 检查端口监听（仅提示） =="
if ss -lntp 2>/dev/null | grep -q ":${LOCAL_PORT} "; then
  ss -lntp | grep ":${LOCAL_PORT} " || true
else
  echo "警告：未检测到 ${LOCAL_PORT} 端口监听。请确认服务已启动。"
fi
echo

echo "== [3/6] Cloudflare 登录授权（需要浏览器） =="
echo "会输出一个 URL，复制到浏览器授权一次即可。"
read -r -p "按回车继续..." _
cloudflared tunnel login || true
echo

echo "== [4/6] 创建/复用 Tunnel =="
if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -Fxq "${TUNNEL_NAME}"; then
  echo "Tunnel 已存在，复用：${TUNNEL_NAME}"
else
  cloudflared tunnel create "${TUNNEL_NAME}"
fi

TUNNEL_ID="$(cloudflared tunnel list | awk -v n="${TUNNEL_NAME}" '$2==n{print $1; exit}')"
if [ -z "${TUNNEL_ID}" ]; then
  echo "错误：无法获取 Tunnel ID"
  exit 1
fi
echo "Tunnel ID：${TUNNEL_ID}"
echo

echo "== [5/6] 写 config.yml + 绑定 DNS =="
mkdir -p "${CLOUDFLARED_DIR}"

CRED_FILE="${CLOUDFLARED_DIR}/${TUNNEL_ID}.json"
if [ ! -f "${CRED_FILE}" ]; then
  echo "警告：未找到凭证文件 ${CRED_FILE}"
  echo "通常创建 tunnel 后会生成；若没有，请执行：cloudflared tunnel create ${TUNNEL_NAME} 并重试。"
fi

cat > "${CONFIG_FILE}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${PUBLIC_HOST}
    service: ${SERVICE_URL}
  - service: http_status:404
EOF

cloudflared tunnel route dns "${TUNNEL_NAME}" "${PUBLIC_HOST}"
echo "已写入：${CONFIG_FILE}"
echo

echo "== [6/6] 安装 systemd 服务并启动 =="
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Cloudflare Tunnel for ${PUBLIC_HOST}
After=network-online.target

[Service]
Type=simple
ExecStart=$(command -v cloudflared) tunnel run ${TUNNEL_NAME}
Restart=on-failure
User=root
WorkingDirectory=${CLOUDFLARED_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared
systemctl restart cloudflared

echo
echo "=========================================="
echo "✅ 完成！访问： https://${PUBLIC_HOST}"
echo "状态： systemctl status cloudflared --no-pager"
echo "日志： journalctl -u cloudflared -f"
echo "=========================================="
