#!/usr/bin/env bash
set -euo pipefail

# =======================
# 可通过环境变量覆盖的默认值
# =======================
: "${INSTALL_MODE:=bin}"                 # bin | deb
: "${CLOUDFLARED_BIN:=/usr/local/bin/cloudflared}"
: "${CLOUDFLARED_DIR:=/root/.cloudflared}"
: "${SERVICE_NAME:=cloudflared}"
: "${STRICT_PORT:=0}"                    # 1=端口不监听则退出；0=仅警告
: "${DENY_PUBLIC_PORT:=0}"               # 1=尝试封死公网对端口访问（ufw优先，其次iptables）；0=不改防火墙

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${CLOUDFLARED_DIR}/config.yml"
CERT_FILE="${CLOUDFLARED_DIR}/cert.pem"

# =======================
# 工具函数
# =======================
log() { echo -e "$*"; }
die() { echo -e "❌ $*" >&2; exit 1; }

has_tty() {
  [ -t 0 ] && [ -t 1 ]
}

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    die "请使用 root 或 sudo 运行。"
  fi
}

arch_tag() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      die "不支持的架构：${m}（目前脚本仅支持 amd64/arm64）"
      ;;
  esac
}

download_cloudflared_bin() {
  local arch
  arch="$(arch_tag)"
  log "安装 cloudflared（单文件二进制，${arch}）..."

  mkdir -p "$(dirname "${CLOUDFLARED_BIN}")"

  local url
  if [ "${arch}" = "amd64" ]; then
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  else
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  fi

  curl -L --fail -o "${CLOUDFLARED_BIN}" "${url}"
  chmod +x "${CLOUDFLARED_BIN}"
}

install_cloudflared_deb() {
  log "安装 cloudflared（.deb 包）..."
  apt update
  apt install -y wget

  local arch
  arch="$(arch_tag)"

  local url
  if [ "${arch}" = "amd64" ]; then
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
  else
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
  fi

  wget -O /tmp/cloudflared.deb "${url}"
  apt install -y /tmp/cloudflared.deb
  rm -f /tmp/cloudflared.deb
}

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "检测到 cloudflared：$(command -v cloudflared)"
    return
  fi

  case "${INSTALL_MODE}" in
    bin) download_cloudflared_bin ;;
    deb) install_cloudflared_deb ;;
    *) die "INSTALL_MODE 必须是 bin 或 deb" ;;
  esac
}

require_login_or_exit() {
  if [ -f "${CERT_FILE}" ]; then
    log "✅ 已检测到授权证书：${CERT_FILE}（跳过登录）"
    return
  fi

  log "❌ 未检测到授权证书：${CERT_FILE}"
  log "Cloudflare Tunnel 第一次必须手动浏览器授权一次。请先执行："
  log ""
  log "  sudo cloudflared tunnel login"
  log ""

  if has_tty; then
    read -r -p "按回车现在开始执行 cloudflared tunnel login..." _
    cloudflared tunnel login || true
    if [ ! -f "${CERT_FILE}" ]; then
      die "登录后仍未生成 ${CERT_FILE}，请确认你在浏览器里已完成授权，并重新运行脚本。"
    fi
  else
    log "检测到当前为非交互环境（例如 curl|bash）。为避免卡住/失败，脚本退出。"
    log "完成上述登录后，再重新运行本脚本即可。"
    exit 1
  fi
}

ensure_tunnel() {
  local tunnel_name="$1"
  if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -Fxq "${tunnel_name}"; then
    log "Tunnel 已存在，复用：${tunnel_name}"
  else
    cloudflared tunnel create "${tunnel_name}"
  fi
}

get_tunnel_id() {
  local tunnel_name="$1"
  cloudflared tunnel list | awk -v n="${tunnel_name}" '$2==n{print $1; exit}'
}

check_port_listen() {
  local port="$1"
  if ss -lntp 2>/dev/null | grep -q ":${port} "; then
    ss -lntp | grep ":${port} " || true
    return 0
  fi
  return 1
}

deny_public_port() {
  local port="$1"
  if [ "${DENY_PUBLIC_PORT}" -ne 1 ]; then
    return
  fi

  log "🔐 尝试封死公网对 ${port}/tcp 的访问（双保险，防绕过）..."

  # UFW 优先
  if command -v ufw >/dev/null 2>&1; then
    ufw deny "${port}/tcp" >/dev/null 2>&1 || true
    log "已通过 ufw 设置 deny ${port}/tcp（若 ufw 未启用不会生效）"
    return
  fi

  # 其次用 iptables（不保证重启后持久）
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${port}" -j DROP || true
    log "已通过 iptables 插入 DROP 规则（注意：重启后可能失效，需自行持久化）"
    return
  fi

  log "提示：系统无 ufw/iptables，跳过防火墙加固。"
}

install_service() {
  local tunnel_name="$1"
  mkdir -p "${CLOUDFLARED_DIR}"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Cloudflare Tunnel (${tunnel_name})
After=network-online.target

[Service]
Type=simple
ExecStart=$(command -v cloudflared) tunnel run ${tunnel_name}
Restart=on-failure
User=root
WorkingDirectory=${CLOUDFLARED_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"
}

uninstall_all() {
  log "停止并移除 systemd 服务..."
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload

  log "删除配置目录：${CLOUDFLARED_DIR}"
  rm -rf "${CLOUDFLARED_DIR}"
  rm -rf /etc/cloudflared

  log "（可选）卸载 deb 包（若你用 deb 安装过）..."
  apt remove --purge -y cloudflared >/dev/null 2>&1 || true

  log "（可选）删除单文件二进制：${CLOUDFLARED_BIN}"
  rm -f "${CLOUDFLARED_BIN}"

  log "✅ 已清理完成。"
  exit 0
}

update_cloudflared() {
  local mode="${INSTALL_MODE}"
  log "更新 cloudflared（模式：${mode}）..."
  if [ "${mode}" = "deb" ]; then
    apt update
    apt install -y cloudflared
  else
    download_cloudflared_bin
  fi
  cloudflared --version || true
  log "✅ 更新完成。"
  exit 0
}

usage() {
  cat <<EOF
用法：
  部署：$0 <域名> <本地端口> [Tunnel名]
  卸载：$0 --uninstall
  更新：$0 --update

环境变量：
  INSTALL_MODE=bin|deb        安装方式（默认 bin）
  STRICT_PORT=1               端口未监听则退出（默认 0）
  DENY_PUBLIC_PORT=1          尝试封死公网对端口访问（默认 0）
EOF
}

# =======================
# 主流程
# =======================
need_root

if [ $# -ge 1 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --uninstall) uninstall_all ;;
    --update) update_cloudflared ;;
  esac
fi

if [ $# -lt 2 ]; then
  usage
  exit 1
fi

PUBLIC_HOST="$1"
LOCAL_PORT="$2"
HOSTNAME_SYS="$(hostname)"
TUNNEL_NAME="${3:-${HOSTNAME_SYS}-web}"
LOCAL_HOST="127.0.0.1"
SERVICE_URL="http://${LOCAL_HOST}:${LOCAL_PORT}"

log "==============================================="
log " 域名            : ${PUBLIC_HOST}"
log " 本地服务        : ${SERVICE_URL}"
log " Tunnel 名称     : ${TUNNEL_NAME}"
log " 安装模式        : ${INSTALL_MODE}"
log "==============================================="
log

log "== [1/7] 确保 cloudflared 已安装 =="
ensure_cloudflared
cloudflared --version || true
log

log "== [2/7] 检查端口监听 =="
if check_port_listen "${LOCAL_PORT}"; then
  log "✅ 端口 ${LOCAL_PORT} 正在监听"
else
  log "⚠️  未检测到 ${LOCAL_PORT} 端口监听。"
  if [ "${STRICT_PORT}" -eq 1 ]; then
    die "STRICT_PORT=1：端口未监听，退出。请先启动你的服务。"
  fi
  log "继续执行（但未来访问可能 502），建议先启动服务再跑。"
fi
log

log "== [3/7] 检查 Cloudflare 授权（cert.pem） =="
require_login_or_exit
log

log "== [4/7] 创建/复用 Tunnel =="
ensure_tunnel "${TUNNEL_NAME}"

TUNNEL_ID="$(get_tunnel_id "${TUNNEL_NAME}")"
[ -n "${TUNNEL_ID}" ] || die "无法获取 Tunnel ID（cloudflared tunnel list 未找到 ${TUNNEL_NAME}）"
log "Tunnel ID：${TUNNEL_ID}"
log

log "== [5/7] 写 config.yml + 绑定 DNS =="
mkdir -p "${CLOUDFLARED_DIR}"
CRED_FILE="${CLOUDFLARED_DIR}/${TUNNEL_ID}.json"

cat > "${CONFIG_FILE}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${PUBLIC_HOST}
    service: ${SERVICE_URL}
  - service: http_status:404
EOF

cloudflared tunnel route dns "${TUNNEL_NAME}" "${PUBLIC_HOST}"
log "已写入：${CONFIG_FILE}"
log

log "== [6/7] 安装 systemd 服务并启动 =="
install_service "${TUNNEL_NAME}"
log

log "== [7/7] 可选：防绕过加固 =="
deny_public_port "${LOCAL_PORT}"
log

log "=========================================="
log "✅ 完成！访问： https://${PUBLIC_HOST}"
log "状态： systemctl status ${SERVICE_NAME} --no-pager"
log "日志： journalctl -u ${SERVICE_NAME} -f"
log "提示：建议确保服务只监听 127.0.0.1，并封死公网端口，避免绕过。"
log "=========================================="
