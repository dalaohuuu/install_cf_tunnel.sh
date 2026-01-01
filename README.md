# Cloudflare Tunnel One-Host

一键把本地服务（如 127.0.0.1:8000）通过 Cloudflare Tunnel 暴露到指定域名，并配置 systemd 自启。

## 1 第一次：手动授权（只做一次）
sudo cloudflared tunnel login

## 2 之后：一键部署
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/install_cf_tunnel.sh/main/install_cf_tunnel.sh | sudo bash -s -- app.example.com 8000
