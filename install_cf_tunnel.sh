#!/usr/bin/env bash
set -e

#############################################
# 参数解析（必须输入前两个参数）
#############################################

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行此脚本。"
  exit 1
fi

# 自动获取主机名
HOSTNAME=$(hostname)

PANEL_HOST="$1"          # 面板域名（Cloudflare Tunnel 入口）
PANEL_LOCAL_PORT="$2"    # 3x-ui 本地面板端口（例如 9999）
TUNNEL_NAME="${3:-${HOSTNAME}-panel}"   # Tunnel 名默认值：主机名 + "-panel"

# 检查第 1 参数：面板域名
if [ -z "$PANEL_HOST" ]; then
  echo "错误：你必须输入面板域名。"
  echo "用法：$0 <面板域名> <本地端口> [Tunnel 名]"
  echo "示例：$0 panela.6568888.xyz 9999"
  exit 1
fi

# 检查第 2 参数：本地端口
if [ -z "$PANEL_LOCAL_PORT" ]; then
  echo "错误：你必须输入本地面板端口。"
  echo "用法：$0 <面板域名> <本地端口> [Tunnel 名]"
  echo "示例：$0 panela.6568888.xyz 9999"
  exit 1
fi

echo "==============================================="
echo " 面板域名      : $PANEL_HOST"
echo " 本地面板端口  : $PANEL_LOCAL_PORT"
echo " Tunnel 名称   : $TUNNEL_NAME"
echo " 主机名        : $HOSTNAME"
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

  echo "cloudflared 安装完成。"
else
  echo "检测到 cloudflared 已安装，跳过安装步骤。"
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
echo "== 步骤 2 / 4：创建 Tunnel：$TUNNEL_NAME =="

CREATE_OUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | tee /tmp/cloudflared_create.log || true)

echo "$CREATE_OUT"

# 尝试从输出中抓 Tunnel ID
TUNNEL_ID=$(echo "$CREATE_OUT" | grep -oE 'ID:\s*[0-9a-f-]+' | awk '{print $2}' | head -n1)

if [ -z "$TUNNEL_ID" ]; then
  echo "未能从 create 输出中解析 Tunnel ID，尝试使用 cloudflared tunnel list..."
  LIST_OUT=$(cloudflared tunnel list 2>/dev/null || true)
  echo "$LIST_OUT"
  TUNNEL_ID=$(echo "$LIST_OUT" | grep "$TUNNEL_NAME" | awk '{print $1}' | head -n1)
fi

if [ -z "$TUNNEL_ID" ]; then
  echo "错误：找不到 Tunnel ID，请检查 cloudflared tunnel create / list 输出。"
  exit 1
fi

echo "已获取 Tunnel ID：$TUNNEL_ID"
echo

#############################################
# 生成 config.yml
#############################################

CLOUDFLARED_DIR="/root/.cloudflared"
if [ ! -d "$CLOUDFLARED_DIR" ]; then
  CLOUDFLARED_DIR="$HOME/.cloudflared"
fi

mkdir -p "$CLOUDFLARED_DIR"

CRED_FILE="$CLOUDFLARED_DIR/${TUNNEL_ID}.json"

if [ ! -f "$CRED_FILE" ]; then
  echo "未在预期路径找到凭据文件：$CRED_FILE"
  echo "尝试自动搜索最近的 json 凭据文件..."
  CRED_FILE=$(ls -t "$CLOUDFLARED_DIR"/*.json 2>/dev/null | head -n1 || true)
fi

if [ ! -f "$CRED_FILE" ]; then
  echo "错误：仍然找不到 credentials json 文件，请检查 $CLOUDFLARED_DIR 下的文件。"
  exit 1
fi

echo "使用 credentials-file: $CRED_FILE"

CONFIG_FILE="$CLOUDFLARED_DIR/config.yml"

cat > "$CONFIG_FILE" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $PANEL_HOST
    service: http://localhost:$PANEL_LOCAL_PORT

  - service: http_status:404
EOF

echo
echo "已生成配置文件：$CONFIG_FILE"
cat "$CONFIG_FILE"
echo

#############################################
# 绑定 DNS 到 Tunnel
#############################################

echo "== 步骤 3 / 4：为 $PANEL_HOST 创建 DNS 记录并绑定 Tunnel =="

cloudflared tunnel route dns "$TUNNEL_NAME" "$PANEL_HOST"

echo
echo "DNS 记录创建完成。"
echo

#############################################
# 创建并启动 systemd 服务
#############################################

echo "== 步骤 4 / 4：创建并启动 systemd 服务 =="

SERVICE_FILE="/etc/systemd/system/cloudflared.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel for 3x-ui panel
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
echo "cloudflared 服务状态："
systemctl status cloudflared --no-pager || true

echo
echo "=========================================="
echo "  完 成 ！"
echo "=========================================="
echo "现在你可以通过以下地址访问面板："
echo "  https://$PANEL_HOST"
echo
echo "建议："
echo "  1. 使用防火墙屏蔽外网访问本地端口 $PANEL_LOCAL_PORT"
echo "  2. Reality 业务域名保持灰色云（DNS Only），确保直连"
echo
echo "查看日志： journalctl -u cloudflared -f"
echo "=========================================="
