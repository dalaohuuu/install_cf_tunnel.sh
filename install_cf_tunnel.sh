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
: "${DENY_PUBLIC_PORT:=0}"               # 1=尝试封死公网端口访问；0=不改防火墙

: "${RECREATE_ON_MISSING_CRED:=1}"       # 1=若 tunnel 存在但缺 json，则自动删除并重建（推荐）；0=直接报错退出

# 3x-ui / HTTPS 场景可覆盖
: "${BACKEND_SCHEME:=http}"              # http | https
: "${NO_TLS_VERIFY:=0}"                  # 1=对后端 https 跳过证书校验（3x-ui 常用）
: "${PATH_REGEX:=}"                      # 例如：^/xxxx(/|$).*   （需要子路径匹配时再设）

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${CLOUDFLARED_DIR}/config.yml"
CERT_FILE="${CLOUDFLARED_DIR}/cert.pem"

log() { echo -e "$*"; }
die() { echo -e "❌ $*" >&2; exit 1; }
has_tty() { [ -t 0 ] && [ -t 1 ]; }

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
    *) die "不支持的架构：${m}（目前仅支持 amd64/arm64）" ;;
  esac
}

download_cloudflared_bin() {
  local arch url
  arch="$(arch_tag)"
  log "安装 cloudflared（单文件二进制，${arch}）..."

  mkdir -p "$(dirname "${CLOUDFLARED_BIN}")"

  if [ "${arch}" = "amd64" ]; then
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  else
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  fi

  command -v curl >/dev/null 2>&1 || apt update && apt install -y curl >/dev/null 2>&1 || true
  curl -L --fail -o "${CLOUDFLARED_BIN}" "${url}"
  chmod +x "${CLOUDFLARED_BIN}"
}

install_cloudflared_deb() {
  local arch url
  log "安装 cloudflared（.deb 包）..."
  apt update
  apt install -y wget

  arch="$(arch_tag)"
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
  mkdir -p "${CLOUDFLARED_DIR}"
  chmod 700 "${CLOUDFLARED_DIR}"

  if [ -f "${CERT_FILE}" ]; then
    log "✅ 已检测到授权证书：${CERT_FILE}（跳过登录）"
    return
  fi

  log "❌ 未检测到授权证书：${CERT_FILE}"
  log "首次使用 Cloudflare Tunnel 需要浏览器授权。请执行："
  log "  sudo cloudflared tunnel login"
  log

  if has_tty; then
    read -r -p "按回车开始执行 cloudflared tunnel login..." _
    cloudflared tunnel login || true
    [ -f "${CERT_FILE}" ] || die "登录后仍未生成 ${CERT_FILE}，请确认浏览器授权已完成。"
  else
    die "当前为非交互环境（例如 curl|bash），无法完成浏览器授权。请手动 cloudflared tunnel login 后再运行。"
  fi
}

tunnel_exists() {
  local tunnel_name="$1"
  cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -Fxq "${tunnel_name}"
}

get_tunnel_id() {
  local tunnel_name="$1"
  cloudflared tunnel list 2>/dev/null | awk -v n="${tunnel_name}" '$2==n{print $1; exit}'
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
  [ "${DENY_PUBLIC_PORT}" -eq 1 ] || return 0

  log "🔐 尝试封死公网对 ${port}/tcp 的访问（防绕过）..."

  if command -v ufw >/dev/null 2>&1; then
    ufw deny "${port}/tcp" >/dev/null 2>&1 || true
    log "已通过 ufw deny ${port}/tcp（若 ufw 未启用可能不生效）"
    return 0
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${port}" -j DROP || true
    log "已通过 iptables 插入 DROP 规则（重启后可能失效，需自行持久化）"
    return 0
  fi

  log "提示：系统无 ufw/iptables，跳过防火墙加固。"
}

write_config() {
  local public_host="$1"
  local service_url="$2"
  local tunnel_id="$3"
  local cred_file="$4"

  cat > "${CONFIG_FILE}" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file}

ingress:
  - hostname: ${public_host}
EOF

  if [ -n "${PATH_REGEX}" ]; then
    cat >> "${CONFIG_FILE}" <<EOF
    path: ${PATH_REGEX}
EOF
  fi

  cat >> "${CONFIG_FILE}" <<EOF
    service: ${service_url}
EOF

  if [ "${BACKEND_SCHEME}" = "https" ] && [ "${NO_TLS_VERIFY}" -eq 1 ]; then
    cat >> "${CONFIG_FILE}" <<'EOF'
    originRequest:
      noTLSVerify: true
EOF
  fi

  cat >> "${CONFIG_FILE}" <<'EOF'
  - service: http_status:404
EOF
}

install_service() {
  local tunnel_name="$1"
  mkdir -p "${CLOUDFLARED_DIR}"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Cloudflare Tunnel (${tunnel_name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v cloudflared) --config ${CONFIG_FILE} tunnel run
Restart=on-failure
RestartSec=2
User=root
WorkingDirectory=${CLOUDFLARED_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
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
  log "更新 cloudflared（模式：${INSTALL_MODE}）..."
  if [ "${INSTALL_MODE}" = "deb" ]; then
    apt update
    apt install -y cloudflared
  else
    download_cloudflared_bin
  fi
  cloudflared --version || true
  log "✅ 更新完成。"
  exit 0
}

status_check() {
  log "==================== Cloudflare Tunnel Status ===================="
  log "时间：$(date)"
  log "cloudflared：$(command -v cloudflared 2>/dev/null || echo '未安装')"
  (cloudflared --version 2>/dev/null || true)
  log

  log "[1] systemd 服务：${SERVICE_NAME}"
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
    systemctl is-active "${SERVICE_NAME}" >/dev/null 2>&1 && log "✅ Active: running" || log "❌ Active: NOT running"
    systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,18p' || true
  else
    log "❌ 未发现 systemd 服务：${SERVICE_NAME}.service"
  fi
  log

  log "[2] 配置目录：${CLOUDFLARED_DIR}"
  ls -l "${CLOUDFLARED_DIR}" 2>/dev/null || true
  log "==============================================================="
  exit 0
}

follow_logs() {
  log "跟踪日志：journalctl -u ${SERVICE_NAME} -f"
  journalctl -u "${SERVICE_NAME}" -f
  exit 0
}

usage() {
  cat <<EOF
用法：
  部署：$0 <域名> <本地端口> [Tunnel名]
  状态：$0 --status
  日志：$0 --logs
  卸载：$0 --uninstall
  更新：$0 --update

环境变量（可选）：
  INSTALL_MODE=bin|deb
  STRICT_PORT=1
  DENY_PUBLIC_PORT=1
  RECREATE_ON_MISSING_CRED=0|1   (默认 1，缺 json 自动删 tunnel 并重建)
  BACKEND_SCHEME=http|https      (默认 http；3x-ui 常用 https)
  NO_TLS_VERIFY=0|1              (默认 0；3x-ui 自签证书建议 1)
  PATH_REGEX='^/xxxx(/|$).*'     (需要子路径匹配时设置，例如 3x-ui webBasePath)
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
    --status) status_check ;;
    --logs) follow_logs ;;
  esac
fi

[ $# -ge 2 ] || { usage; exit 1; }

PUBLIC_HOST="$1"
LOCAL_PORT="$2"
HOSTNAME_SYS="$(hostname)"
TUNNEL_NAME="${3:-${HOSTNAME_SYS}-web}"
LOCAL_HOST="127.0.0.1"
SERVICE_URL="${BACKEND_SCHEME}://${LOCAL_HOST}:${LOCAL_PORT}"

log "==============================================="
log " 域名            : ${PUBLIC_HOST}"
log " 本地服务        : ${SERVICE_URL}"
log " Tunnel 名称     : ${TUNNEL_NAME}"
log " 安装模式        : ${INSTALL_MODE}"
log " 子路径匹配      : ${PATH_REGEX:-<无>}"
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
  log "继续执行（未来可能 502），建议先启动服务再跑。"
fi
log

log "== [3/7] 检查 Cloudflare 授权（cert.pem） =="
require_login_or_exit
log

log "== [4/7] 创建/复用 Tunnel 并确保凭据 json 存在 =="
if tunnel_exists "${TUNNEL_NAME}"; then
  log "Tunnel 已存在，复用：${TUNNEL_NAME}"
else
  cloudflared tunnel create "${TUNNEL_NAME}"
fi

TUNNEL_ID="$(get_tunnel_id "${TUNNEL_NAME}")"
[ -n "${TUNNEL_ID}" ] || die "无法获取 Tunnel ID（tunnel list 未找到 ${TUNNEL_NAME}）"
CRED_FILE="${CLOUDFLARED_DIR}/${TUNNEL_ID}.json"

# 关键：如果本机缺少 json，就无法运行。此时可选择自动删 tunnel 并重建。
if [ ! -f "${CRED_FILE}" ]; then
  log "⚠️  未发现 tunnel 凭据：${CRED_FILE}"
  if [ "${RECREATE_ON_MISSING_CRED}" -eq 1 ]; then
    log "将自动删除 Cloudflare 侧同名 tunnel 并重建（以重新生成 json）..."
    cloudflared tunnel delete -f "${TUNNEL_NAME}" || true
    cloudflared tunnel create "${TUNNEL_NAME}"

    TUNNEL_ID="$(get_tunnel_id "${TUNNEL_NAME}")"
    [ -n "${TUNNEL_ID}" ] || die "重建后仍无法获取 Tunnel ID"
    CRED_FILE="${CLOUDFLARED_DIR}/${TUNNEL_ID}.json"
  else
    die "缺少 ${CRED_FILE}。请在 Zero Trust 后台下载 credentials(json) 放到该路径，或设 RECREATE_ON_MISSING_CRED=1 自动重建。"
  fi
fi

[ -f "${CRED_FILE}" ] || die "仍未生成 credentials json：${CRED_FILE}"
chmod 600 "${CRED_FILE}" || true
log "✅ Tunnel：${TUNNEL_NAME}"
log "✅ Tunnel ID：${TUNNEL_ID}"
log "✅ 凭据文件：${CRED_FILE}"
log

log "== [5/7] 写 config.yml + 绑定 DNS =="
mkdir -p "${CLOUDFLARED_DIR}"
write_config "${PUBLIC_HOST}" "${SERVICE_URL}" "${TUNNEL_ID}" "${CRED_FILE}"

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
log "=========================================="
