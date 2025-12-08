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
  echo "示例：$0 panel.example.com 9999"
  exit 1
fi

# 检查第 2 参数：本地端口
if [ -z "$PANEL_LOCAL_PORT" ]; then
  echo "错误：你必须输入本地面板端口。"
  echo "用法：$0 <面板域名> <本地端口> [Tunnel 名]"
  echo "示例：$0 panel.example.com 9999"
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

cloudflared tunnel login

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
  echo
