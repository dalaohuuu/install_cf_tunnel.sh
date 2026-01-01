#!/usr/bin/env bash
set -euo pipefail

#############################################
# 参数解析（必须输入前 2 个参数）
#############################################

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本。"
  exit 1
fi

HOSTNAME_SYS=$(hostname)

PUBLIC_HOST="$1"        # 运行时指定：对外访问域名（子域名/根域名均可）
LOCAL_PORT="$2"         # 本地服务端口（如 8000）
TUNNEL_NAME="${3:-${HOSTNAME_SYS}-web}"   # Tunnel 名（可选）
LOCAL_HOST="127.0.0.1"
SERVICE_URL="http://${LOCAL_HOST}:${LOCAL_PORT}"

# 参数检查
if [ -z "${PUBLIC_HOST:-}" ] || [ -z "${LOCAL_PORT:-}" ]; then
  echo "错误：参数不足。"
  echo "用法：$0 <域名> <本地端口> [Tunnel 名]"
  echo "示例：$0 app.example.com 8000"
  exit 1
fi

echo "==============================================="
echo " 域名            : $PUBLIC_HOST"
echo " 本地服务        : $SERVICE_URL"
echo " Tunnel 名称     : $TUNNEL_NAME"
echo " 主机名          : $HOSTNAME_SYS"
echo "==============================================="
echo

#############################################
# 安装 cloudflared（如未安装）
# 说明：你现在已经用二进制安装过了，此段依旧兼容；
# 若未安装，则用 .deb 安装（Debian/Ubuntu）
#############################################

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "未检测到 cloudflared，开始安装（Debian/Ubuntu）..."
  apt update
  apt install -y wget
  wget -O /tmp/cloudflared-linux-amd64.deb \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb

  apt install -y /tmp/cloudflared-linux-amd64.deb
  rm -f /tmp/cloudflared-linux-amd64.deb
else
  echo "cloudflared 已安装，跳过安装步骤。"
fi

echo
echo "cloudflared 版本：$(cloudflared --version || echo '未知')"
echo

#############################################
# 检查本地端口是否监听（仅提醒，不阻断）
#############################################

echo "== 检查本地端口监听：$LOCAL_PORT =="
if ss -lntp 2>/dev/null | grep -q ":${LOCAL_PORT} "; then
  ss -lntp | grep ":${LOCAL_PORT} " || true
else
  echo "警告：未检测到 ${LOCAL_PORT} 端口监听。请确认你的服务已启动。"
fi
echo

#############################################
# Cloudflare 登录（需要浏览器授权）
#############################################

echo "======================================================"
echo " 现在必须完成 Cloudflare 登录授权，否则 Tunnel 无法创建"
echo " 稍后终端会输出一个 URL，请复制到浏览器手动登录一次"
echo "======================================================"
echo
read -r -p "按回车执行 cloudflared tunnel login..." _

cloudflared tunnel login || true

#############################################
# 创建/复用 Tunnel
#############################################

echo
echo "== 创建/复用 Tunnel：$TUNNEL_NAME =="

if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -Fxq "$TUNNEL_NAME"; then
  echo "Tunnel 已存在，复用：$TUNNEL_NAME"
else
  cloudflared tunnel create "$TUNNEL_NAME"
fi

# 获取 Tunnel ID（更稳：直接从 list 里取）
TUNNEL_ID="$(cloudflared tunnel list | awk -v n="$TUNNEL_NAME" '$2==n{print $1; exit}')"

if [ -z "${TUNNEL_ID:-}" ]; then
  echo "错误：无法获取 Tunnel ID（cloudflared tunnel list 未找到 $TUNNEL_NAME）"
  exit 1
fi

echo "Tunnel ID：$TUNNEL_ID"
echo

#############################################
# 生成 config.yml
#############################################

CLOUDFLARED_DIR="/root/.cloudflared"
mkdir -p "$CLOUDFLARED_DIR"

CRED_FILE="$CLOUDFLARED_DIR/${TUNNEL_ID}.json"
CONFIG_FILE="$CLOUDFLARED_DIR/config.yml"

cat > "$CONFIG_FILE" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $PUBLIC_HOST
    service: $SERVICE_URL
  - service: http_status:404
EOF

echo "已生成配置文件：$CONFIG_FILE"
cat "$CONFIG_FILE"
echo

#############################################
# 绑定 DNS
#############################################

echo "== 绑定 DNS：$PUBLIC_HOST =="
cloudflared tunnel route dns "$TUNNEL_NAME" "$PUBLIC_HOST"
echo

#############################################
# systemd 服务
#############################################

SERVICE_FILE="/etc/systemd/system/cloudflared.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel for ${PUBLIC_HOST}
After=network-online.target

[Service]
Type=simple
ExecStart=$(command -v cloudflared) tunnel run $TUNNEL_NAME
Restart=on-failure
User=root
WorkingDirectory=$CLOUDFLARED_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

echo
echo "=========================================="
echo "  完 成 ！"
echo "=========================================="
echo "访问地址： https://$PUBLIC_HOST"
echo "查看状态： systemctl status cloudflared --no-pager"
echo "查看日志： journalctl -u cloudflared -f"
echo "=========================================="
