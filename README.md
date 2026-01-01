# Cloudflare Tunnel One-Host Installer

一个 一键脚本，用于将本地服务（如 127.0.0.1:8000）通过 Cloudflare Tunnel 暴露到指定域名，并自动配置 systemd 自启。

## 适用于：

希望 隐藏真实 IP、只走 Cloudflare 的场景

## 特性

- ✅ 一条命令部署 Cloudflare Tunnel

- ✅ 自动识别 amd64 / arm64

- ✅ 支持二进制 / .deb 安装方式

- ✅ 自动创建 / 复用 Tunnel

- ✅ 自动绑定 DNS（CNAME → Tunnel）

- ✅ systemd 自启

- ✅ 内置健康检查（--status）

- ✅ 内置日志查看（--logs）

- ✅ 支持卸载 / 更新

- ✅ 兼容 curl | bash

- ✅ 适配 Ubuntu 20.04 / 22.04 / 24.04（Debian 同理）

## 使用前提

- 域名已接入 Cloudflare

- VPS 能访问公网

- 本地服务已经在监听（如 127.0.0.1:8000）

- 首次使用需要浏览器授权 Cloudflare（一次性）

## 快速开始
- 1️⃣ 首次授权（只需要做一次）
```
sudo cloudflared tunnel login
```
终端会输出一个 URL，用浏览器打开并完成授权即可。
成功后会生成：
```
/root/.cloudflared/cert.pem
```
- 2️⃣ 一键部署 Tunnel
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/install_cf_tunnel.sh/main/install_cf_tunnel.sh \
  | sudo bash -s -- app.example.com 8000
```

- 参数说明：
app.example.com   对外访问的域名（子域名或根域名）
8000              本地服务端口（127.0.0.1:8000）
- 可选指定 Tunnel 名：
```
curl -fsSL ... | sudo bash -s -- app.example.com 8000 my-tunnel
```
## 常用命令
- 查看运行状态（强烈推荐）
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/install_cf_tunnel.sh/main/install_cf_tunnel.sh \
  | sudo bash -s -- --status
```

📌 首次没 cert.pem 的话，--status 会告诉你缺什么（比如没登录、没 config、服务没跑、DNS 不像 tunnel 等）。

## 查看实时日志
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/install_cf_tunnel.sh/main/install_cf_tunnel.sh \
  | sudo bash -s -- --logs
```

等价于：
```
journalctl -u cloudflared -f
```
## 更新 cloudflared
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/install_cf_tunnel.sh/main/install_cf_tunnel.sh \
  | sudo bash -s -- --update
```
## 卸载并清理
```
curl -fsSL https://raw.githubusercontent.com/dalaohuuu/install_cf_tunnel.sh/main/install_cf_tunnel.sh \
  | sudo bash -s -- --uninstall
```
会清理：

- systemd 服务
- /root/.cloudflared
- 可选删除 cloudflared 程序

## 可选环境变量
- 端口未监听直接退出（严格模式）
```
STRICT_PORT=1 curl -fsSL ... | sudo bash -s -- app.example.com 8000
```
- 自动封死公网直连端口（防绕过）
```
DENY_PUBLIC_PORT=1 curl -fsSL ... | sudo bash -s -- app.example.com 8000
```

## 说明：

- 优先使用 ufw
- 否则使用 iptables
- 目的是防止绕过 Cloudflare 直接访问 VPS IP

## 安装后如何确认是否正常

推荐顺序：
```
systemctl status cloudflared
```
```
cloudflared tunnel list
```
```
ss -lntp | grep :8000
```
curl -I http://127.0.0.1:8000
```
```
curl -I https://app.example.com
```
全部正常即可确认 Tunnel 工作正常。

## 常见问题（FAQ）
- Q1：提示找不到 cert.pem

原因：还没执行 cloudflared tunnel login
解决：
```
sudo cloudflared tunnel login
```
- Q2：域名能访问，但返回 502
常见原因：
本地服务没启动
端口监听在 0.0.0.0 但服务异常
服务返回非 HTTP
排查：
```
ss -lntp | grep :8000
```
```
curl http://127.0.0.1:8000
```
- Q3：域名没走 Tunnel，而是指向 VPS IP
原因：DNS 记录不正确
检查：
```
dig +short app.example.com
```
正常应解析到 cfargotunnel.com

- Q4：能直接通过 VPS IP:8000 访问（不安全）
解决方案：
服务只监听 127.0.0.1
或启用：
```
DENY_PUBLIC_PORT=1 ...
```
## 安全建议

- 强烈建议：服务仅监听 127.0.0.1

- 不要在 Cloudflare DNS 中手动添加 A 记录指向 VPS IP

- 生产环境可叠加 Cloudflare WAF / Access

## 许可

MIT License
欢迎 Fork / PR / 自用 / 魔改。
