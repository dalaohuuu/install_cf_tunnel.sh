#!/usr/bin/env bash
set -e

#############################################
# 参数解析（必须输入前 3 个参数）
#############################################

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本。"
  exit 1
fi

# 自动获取主机名用于 Tunnel 默认名
HOSTNAME=$(hostname)

PANEL_HOST="$1"        # 运行时指定：面板域名
PANEL_LOCAL_PORT="$2"  # 本地面板端口（如 9999）
SUB_HOST="$3"          # 运行时指定：订阅域名
TUNNEL_NAME="${4:-${HOSTNAME}-panel}"   # Tunnel 名（可选）

SUB_LOCAL_PORT=2096    # 固定订阅本地端口

# 参数检查
if [ -z "$PANEL_HOST" ] || [ -z "$PANEL_LOCAL_PORT" ] || [ -z "$SUB_HOST" ]; then
  echo "错误：参数不足。"
  echo "用法：$0 <面板域名> <本地端口> <订阅域名> [Tunnel 名]"
  echo "示例：$0 paneldmit.6568888.xyz 9999 subdmit.6568888.xyz"
  exit 1
fi

echo "==============================================="
echo " 面板域名        : $PANEL_HOST"
echo " 本地面板端口    : $PANEL_LOCAL_PORT"
echo " 订阅域名        : $SUB_HOST"
echo " 本地订阅端口    : $SUB_LOCAL_PORT"
echo " Tunnel 名称     : $TUNNEL_NAME"
echo " 主机名          : $HOSTNAME"
echo "==============================================="
echo

#############################################
# 安装 cloudflared（如未安装）
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
# Cloudflare 登录
#############################################

echo "======================================================"
echo " 现在必须完成 Cloudflare 登录授权，否则 Tunnel 无法创建"
echo " 稍后终端会输出一个 URL，请复制到浏览器手动登录一次"
echo "======================================================"
echo
read -p "按回车执行 cloudflared tunnel login..." _

cloudflared tunnel login || true

#############################################
# 创建 Tunnel
#############################################

echo
echo "== 创建 Tunnel：$TUNNEL_NAME =="

CREATE_OUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | tee /tmp/cloudflared_create.log || true)

# 解析 Tunnel ID
TUNNEL_ID=$(echo "$CREATE_OUT" | grep -oE 'ID:\s*[0-9a-f-]+' | awk '{print $2}' | head -n1)

if [ -z "$TUNNEL_ID" ]; then
  LIST_OUT=$(cloudflared tunnel list 2>/dev/null || true)
  TUNNEL_ID=$(echo "$LIST_OUT" | grep "$TUNNEL_NAME" | awk '{print $1}' | head -n1)
fi

if [ -z "$TUNNEL_ID" ]; then
  echo "错误：无法获取 Tunnel ID"
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
  - hostname: $PANEL_HOST
    service: http://localhost:$PANEL_LOCAL_PORT

  - hostname: $SUB_HOST
    service: http://localhost:$SUB_LOCAL_PORT

  - service: http_status:404
EOF

echo
echo "已生成配置文件：$CONFIG_FILE"
cat "$CONFIG_FILE"
echo

#############################################
# 绑定 DNS
#############################################

echo "== 绑定 DNS：$PANEL_HOST =="
cloudflared tunnel route dns "$TUNNEL_NAME" "$PANEL_HOST"

echo
echo "== 绑定 DNS：$SUB_HOST =="
cloudflared tunnel route dns "$TUNNEL_NAME" "$SUB_HOST"

#############################################
# systemd 服务
#############################################

SERVICE_FILE="/etc/systemd/system/cloudflared.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel for panel & subscription
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
echo "面板访问地址： https://$PANEL_HOST"
echo "订阅访问地址： https://$SUB_HOST"
echo "=========================================="
