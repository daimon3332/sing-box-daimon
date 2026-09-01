# sing-box-daimon

## 使用方法

在 VPS 上使用 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daimon3332/sing-box-daimon/main/sb.sh)
```

或手动下载后执行：

```bash
curl -fsSLo sb.sh https://raw.githubusercontent.com/daimon3332/sing-box-daimon/main/sb.sh
chmod +x sb.sh
sudo ./sb.sh
```

安装完成后，可直接进入管理菜单：

```bash
sb
sing-box
```

脚本自动识别 Debian 或 Alpine。安装菜单提供两种模式：

- `3. 标准安装 Sing-box`：Debian 等 systemd 系统的完整协议、二维码和 HTTP/HTTPS 订阅能力；Alpine 不支持此模式。
- `13. NAT 轻量安装：仅 Vless-reality`：支持 Debian 与 Alpine，面向 64 MB 等低内存 NAT 容器，只运行 VLESS Reality。

NAT 轻量安装只询问一次客户端连接 IPv4、IPv6 或域名；监听端口自动生成，不询问外部端口。请在 NAT 服务商面板把显示的端口映射到相同内部端口。该模式不安装 OpenSSL、qrencode、自签证书或 Python 订阅进程，也不提供 HTTP/HTTPS 订阅和二维码，只显示可直接导入客户端的 VLESS 链接。Debian 使用 Python 做短时状态管理但不常驻；Alpine 不安装 Python，使用 jq 管理状态并由 OpenRC 托管 sing-box。Debian 可通过菜单 `3` 原地升级到标准模式，Alpine 只支持菜单 `13`。

NAT 模式会先检查必需命令，依赖齐全时完全跳过包管理器。低内存 Debian 缺少依赖时，脚本从 Debian 官方索引流式筛选所需包、校验 SHA256，再由 dpkg 分阶段安装，不执行高峰值的常规 `apt-get update`。Alpine 只补实际缺少的 Bash、curl、CA 或 jq；sing-box APK 先通过系统 APK 密钥校验签名，再用 BusyBox tar 只提取原生主程序，不把 sing-box 安装进 APK 包数据库。两种系统都使用限速下载、周期同步写盘和同文件系统原子替换。当前最低实测环境为 64 MB RAM、64 MB swap，覆盖 Debian 13 与 Alpine 3.24 x86_64。

极简 Alpine 如果尚无 Bash，需要先执行 `apk add --no-cache bash`，再运行上面的安装命令；脚本启动后会自动补齐其余缺失依赖。

手动彻底删除脚本、sing-box、节点、订阅服务、脚本托管的 UFW 规则和跳跃端口转发：

```bash
sudo bash -c '
set -e
ROOT=/etc/sing-box
STATE=$ROOT/state.json
DOMAIN=""
[ -s "$STATE" ] && DOMAIN=$(python3 -c "import json;print(json.load(open(\"$STATE\")).get(\"sub_domain\", \"\"))" 2>/dev/null || true)

systemctl disable --now sing-box sing-box-sub >/dev/null 2>&1 || true
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box-sub.service
systemctl daemon-reload >/dev/null 2>&1 || true

if command -v ufw >/dev/null 2>&1 && [ -s "$ROOT/firewall/ufw.rules" ]; then
  while read -r rule; do
    [ -n "$rule" ] && ufw --force delete allow "$rule" >/dev/null 2>&1 || true
  done < "$ROOT/firewall/ufw.rules"
fi

for proto in hysteria2 tuic; do
  comment="sing-box-daimon-${proto}-hopping"
  while iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--comment $comment" >/dev/null; do
    iptables -t nat -S PREROUTING | grep -F -- "--comment $comment" | head -n1 | sed "s/^-A /-D /" | xargs -r iptables -t nat 2>/dev/null || break
  done
  while ip6tables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--comment $comment" >/dev/null; do
    ip6tables -t nat -S PREROUTING | grep -F -- "--comment $comment" | head -n1 | sed "s/^-A /-D /" | xargs -r ip6tables -t nat 2>/dev/null || break
  done
done

rm -f /etc/nginx/sites-available/sing-box-daimon-sub /etc/nginx/sites-enabled/sing-box-daimon-sub
[ -n "$DOMAIN" ] && [ -x /root/.acme.sh/acme.sh ] && /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1 || true
[ -n "$DOMAIN" ] && rm -rf "/root/domain/$DOMAIN"
command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true

[ "$(readlink -f /usr/local/bin/sb 2>/dev/null || true)" = "$ROOT/sb.sh" ] && rm -f /usr/local/bin/sb
[ "$(readlink -f /usr/local/bin/sing-box 2>/dev/null || true)" = "$ROOT/sb.sh" ] && rm -f /usr/local/bin/sing-box
rm -rf "$ROOT"
'
```

Mixed/SOCKS5 curl 测试使用明文账号密码：

```bash
curl -x 'socks5://daimon:daimon@IP:30000' https://ip.sb
```

## 固定测试清单

下面命令用于每次改完脚本后的复测。先在 VPS 菜单执行：

```text
1. 更新脚本
3. 标准安装 Sing-box
6. 一键添加协议：Mixed / Vless-reality / Vmess-ws / Hysteria-2 / Tuic-v5 / Anytls
```

记录菜单里展示的 `IP`、`token`、各协议端口。下面示例变量按实际值替换：

```bash
IP=162.141.137.231
TOKEN=00060f83f401721e99f97ec32242c774
SUB_PORT=2096
SOCKS_PORT=30000
```

### 1. VPS 服务器测试

在 VPS 上执行：

```bash
grep '^SCRIPT_VERSION=' /etc/sing-box/sb.sh
systemctl is-active sing-box
systemctl is-active sing-box-sub
/etc/sing-box/bin/sing-box check -C /etc/sing-box/conf
curl -fsS "http://127.0.0.1:${SUB_PORT}/sub/${TOKEN}/clash" | head -n 30
curl -4 --max-time 15 -x "socks5://daimon:daimon@127.0.0.1:${SOCKS_PORT}" https://ip.sb
ss -lntup | grep -E 'sing-box|python|:2096|:30000'
ufw status
```

通过标准：

- `systemctl is-active` 都返回 `active`
- `sing-box check` 返回码为 `0`
- Clash 订阅开头包含 `mixed-port`、`proxies`
- SOCKS5 curl 返回服务器出口 IP
- UFW inactive 时无需放行；UFW active 时状态页不能出现缺失端口

HTTPS 订阅域名测试。先在菜单 `11. 更改综合订阅配置` 里选择 `3. 设置/更改 HTTPS 订阅域名`，输入已解析到本机 IP 的域名，例如：

```text
sing-box-hk.333186.xyz
```

然后执行：

```bash
DOMAIN=sing-box-hk.333186.xyz
curl -I "https://${DOMAIN}/sub/${TOKEN}"
curl -fsS "https://${DOMAIN}/sub/${TOKEN}/clash" | head -n 30
curl -fsS "http://${IP}:${SUB_PORT}/sub/${TOKEN}/clash" | head -n 30
nginx -t
systemctl is-active nginx
ls -l /etc/nginx/sites-available/sing-box-daimon-sub /etc/nginx/sites-enabled/sing-box-daimon-sub
ls -l "/root/domain/${DOMAIN}/fullchain.pem" "/root/domain/${DOMAIN}/privkey.pem"
```

通过标准：

- HTTPS 域名订阅返回 `200`
- `/clash` 返回 YAML
- HTTP/IP 订阅仍然可用
- `nginx -t` 成功，`nginx` 为 `active`

### 2. 本地 SOCKS5 curl 测试

Windows PowerShell：

```powershell
$IP = "162.141.137.231"
$SOCKS_PORT = 30000
curl.exe -4 --connect-timeout 8 --max-time 20 -x "socks5://daimon:daimon@${IP}:${SOCKS_PORT}" https://ip.sb
```

通过标准：输出为服务器 IP。不要使用 `socks://base64账号密码@IP:端口` 测 curl；脚本生成的 SOCKS5 明文链接是：

```text
socks5://daimon:daimon@IP:30000#Mixed-SOCKS5
```

### 3. 本地 Clash / Mihomo 订阅与节点测试

默认 Mihomo 路径示例：`D:\mihomo\mihomo.exe`。在仓库目录运行 PowerShell：

```powershell
$IP = "162.141.137.231"
$TOKEN = "替换为菜单显示的token"
$SUB_PORT = 2096
$Mihomo = "D:\mihomo\mihomo.exe"
$Dir = ".tmp\mihomo-test"
$Remote = "$Dir\remote.yaml"
$Config = "$Dir\config.yaml"
$Home = "$Dir\home"

New-Item -ItemType Directory -Force $Dir,$Home | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "http://${IP}:${SUB_PORT}/sub/${TOKEN}/clash" -OutFile $Remote

$content = Get-Content $Remote -Raw
$content = $content -replace 'mixed-port:\s*7890', 'mixed-port: 19090'
$content = $content -replace 'allow-lan:\s*false', "allow-lan: false`nexternal-controller: 127.0.0.1:19091`nsecret: ''"
Set-Content -Path $Config -Value $content -Encoding UTF8

$outLog = "$Dir\mihomo.out.log"
$errLog = "$Dir\mihomo.err.log"
$p = Start-Process -FilePath $Mihomo -ArgumentList @("-d", $Home, "-f", $Config) `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 5

$names = @("Vless-reality","Vmess-ws","Hysteria-2","Tuic-v5","Anytls","Trojan","Shadowsocks","Vmess-tcp","Vmess-http","Mixed-SOCKS5")
foreach ($name in $names) {
  Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:19091/proxies/PROXY" `
    -Body (@{ name = $name } | ConvertTo-Json -Compress) -ContentType "application/json" | Out-Null
  Start-Sleep -Seconds 1
  Write-Host "=== $name ==="
  curl.exe -4 -k --connect-timeout 8 --max-time 25 -x http://127.0.0.1:19090 https://ip.sb
}

Stop-Process -Id $p.Id -Force
```

通过标准：所有节点都返回服务器 IP，Mihomo 日志里能看到：

```text
using PROXY[Vless-reality]
using PROXY[Vmess-ws]
using PROXY[Hysteria-2]
using PROXY[Tuic-v5]
using PROXY[Anytls]
using PROXY[Trojan]
using PROXY[Shadowsocks]
using PROXY[Vmess-tcp]
using PROXY[Vmess-http]
using PROXY[Mixed-SOCKS5]
```

### 4. 本地 v2rayN 订阅拉取验证

默认 v2rayN 路径示例：`D:\v2rayN-windows-64`。先验证默认订阅是 v2rayN Base64，且包含 6 类节点：

```powershell
$IP = "162.141.137.231"
$TOKEN = "替换为菜单显示的token"
$SUB_PORT = 2096
$Dir = ".tmp\v2rayn-test"
$Sub = "$Dir\v2rayn-sub.txt"
$Decoded = "$Dir\v2rayn-decoded.txt"

New-Item -ItemType Directory -Force $Dir | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "http://${IP}:${SUB_PORT}/sub/${TOKEN}" -OutFile $Sub
$text = Get-Content $Sub -Raw
$decodedText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text.Trim()))
Set-Content -Path $Decoded -Value $decodedText -Encoding UTF8

$required = @("vless://","vmess://","v2rayn://hysteria2/","v2rayn://tuic/","v2rayn://anytls/","trojan://","ss://","socks://")
foreach ($item in $required) {
  if ($decodedText -notlike "*$item*") { throw "missing $item" }
}
Get-Content $Decoded
```

通过标准：能看到以下类型：

```text
vless://
vmess://
v2rayn://hysteria2/
v2rayn://tuic/
v2rayn://anytls/
trojan://
ss://
socks://
```

如果要做 v2rayN core 连通测试，使用 v2rayN 自带 core：

```powershell
D:\v2rayN-windows-64\bin\sing_box\sing-box.exe version
```

版本应支持 Hy2、TUIC、AnyTLS。再将订阅导入 v2rayN GUI 后逐个测速；Hy2/TUIC/AnyTLS 应由 sing-box core 运行，证书验证应显示为跳过验证。

## 订阅形式

标准模式的订阅服务默认端口为 `2096`，token 随机生成且只包含字母和数字。可以在菜单 `11. 更改综合订阅配置` 中修改订阅端口、指定 token 或回车随机重生成 token。NAT 轻量模式不启动订阅服务。

```text
http://IP:2096/sub/token          # 默认订阅：v2rayN Base64
http://IP:2096/sub/token/v2rayn   # v2rayN Base64
http://IP:2096/sub/token/clash    # Clash/Mihomo YAML
http://IP:2096/sub/token/mihomo   # Clash/Mihomo YAML
http://IP:2096/sub/token/raw      # 原始单行分享链接
```

如果配置了 HTTPS 订阅域名，会额外展示：

```text
https://域名/sub/token          # 默认订阅：v2rayN Base64
https://域名/sub/token/v2rayn   # v2rayN Base64
https://域名/sub/token/clash    # Clash/Mihomo YAML
https://域名/sub/token/mihomo   # Clash/Mihomo YAML
https://域名/sub/token/raw      # 原始单行分享链接
```

HTTP/IP 订阅始终保留；HTTPS 域名订阅只是额外增加。域名订阅只使用 HTTPS，不提供域名 HTTP 入口。

HTTPS 域名订阅使用 Nginx + acme.sh，不使用 Caddy。使用前需要提前把域名 A/AAAA 记录解析到 VPS IP。设置域名时脚本会自动安装或复用 Nginx、安装或复用 acme.sh、申请 Let's Encrypt 证书、写入 Nginx 反代配置、配置证书自动续期。证书申请失败时会提示失败，不继续写入 Nginx 订阅配置。删除 HTTPS 域名时只删除本脚本托管的 Nginx 配置和该域名证书，不卸载 Nginx。

### v2rayN

v2rayN 使用默认订阅或 `/v2rayn`：

```text
http://IP:2096/sub/token
http://IP:2096/sub/token/v2rayn
```

默认订阅输出 Base64，包含 VLESS Reality、VMess WS、Hysteria2、TUIC v5、AnyTLS、Mixed/SOCKS5。Hy2/TUIC/AnyTLS 使用 v2rayN 专用链接指定 sing-box core；Hy2/TUIC 会嵌入自签证书并关闭不安全跳过验证，Mixed 使用标准 `socks://` 链接，兼容新版 v2rayN。

执行菜单 `1. 更新脚本` 时会保留现有协议、端口和认证参数，并自动重新生成 v2rayN、Clash/Mihomo 和原始订阅后重启订阅服务。

### Clash / Mihomo

Clash/Mihomo 必须使用 YAML 订阅：

```text
http://IP:2096/sub/token/clash
http://IP:2096/sub/token/mihomo
```

推荐明确使用 `/clash` 或 `/mihomo`。不带后缀的默认订阅会根据 User-Agent 自动给 Clash/Mihomo 返回 YAML；如果客户端没有标准 User-Agent，则默认返回 v2rayN Base64。

## 功能

`sb.sh` 是自定义 sing-box 管理脚本，使用官方 sing-box 内核和 `/etc/sing-box/conf/*.json` 拆分配置。

- 快捷命令：安装后支持 `sb` 和 `sing-box` 进入管理菜单
- 安装管理：标准安装、NAT 轻量 VLESS Reality 安装、删除卸载、更新脚本、删除脚本
- 状态页：脚本版本、最新状态、UFW 状态、缺失端口、系统、内核、架构、虚拟化、BBR、IP、地区、服务状态
- 协议管理：Mixed、VLESS Reality、VMess WS、Hysteria2、TUIC v5、AnyTLS、Trojan、Shadowsocks、VMess TCP、VMess HTTP
- 一键添加协议：一次生成 Mixed / VLESS Reality / VMess WS / Hysteria2 / TUIC v5 / AnyTLS
- 添加协议时自动检测公网 IPv4/IPv6：可使用检测地址，也可手动输入客户端连接地址
- 一键添加协议只询问一次客户端连接地址，并应用到本次新建的全部默认协议
- NAT 轻量安装只生成 VLESS Reality，一次选择客户端连接地址并自动生成监听端口和认证参数
- NAT 轻量模式不安装 OpenSSL、qrencode、自签证书或订阅进程；Debian 可通过标准安装原地升级，Alpine 保持仅 VLESS Reality
- NAT 依赖齐全时不调用包管理器；缺失依赖时流式筛选官方索引并分阶段安装
- NAT 内核不落地压缩包和非必要运行库，使用限速流式解压、周期写盘和同文件系统原子替换
- 添加协议时支持放弃自动检测，手动输入客户端连接 IPv4、IPv6 或域名，适配 NAT 入口地址
- NAT 模式节点端口继续使用内部监听端口，外部相同端口映射由用户在 NAT 服务商页面配置
- 每个协议独立保存客户端连接地址，可在修改协议菜单中切换；不限制 VPS 的 Direct 出站
- 手动添加协议额外支持 Trojan、Shadowsocks、VMess TCP、VMess HTTP；一键添加协议保持精简默认组合
- 添加、更改、删除协议后会立即检查配置并应用运行态；删除所有协议会停止 sing-box
- 查看协议时只读取并显示节点信息，不会重建配置或改动防火墙
- 查看协议时显示每个节点的单行链接、二维码和综合订阅链接
- 删除协议支持多选和一键删除所有协议
- Mixed/SOCKS5 默认账号密码：`daimon` / `daimon`
- Mixed/SOCKS5 默认端口从 `30000` 开始，其余协议默认随机使用高位端口
- SOCKS5 分享链接使用明文 `用户名:密码`
- Reality SNI 随机使用 `www.bing.com`、`www.amazon.com`、`www.apple.com`，并支持自定义
- Hysteria2 支持 UDP 跳跃端口转发；TUIC 不再提供半实现跳跃端口入口
- Hysteria2/TUIC 默认使用自签证书，客户端订阅默认跳过证书验证
- 自动检测 TCP/UDP 端口占用，避免配置端口重复
- 综合订阅支持修改端口、指定 token、回车随机重生成 token、设置或删除 HTTPS 订阅域名
- HTTPS 订阅域名使用 Nginx + acme.sh 自动申请和续期证书；HTTP/IP 订阅同时保留
- 订阅服务使用双栈监听，IPv6-only VPS 的 `http://[IPv6]:端口/sub/...` 链接同样可用；不支持 IPv6 时自动回落 IPv4
- 订阅文件缺失时返回 404、状态文件损坏时返回 503，不再返回 500 并暴露异常堆栈
- `state.json` 采用临时文件加原子替换写入，写入过程被中断不会损坏节点参数，客户端也不会拉到残缺内容
- 每次生成订阅会清理非当前 token 的订阅文件，避免旧 token 内容留在磁盘上
- 状态读取使用进程内缓存，菜单渲染只加载一次；缓存文件仅接受预期格式，损坏或旧格式会重建而不会被执行
- 内核下载在 GitHub API 触发限流时自动改用 `releases/latest` 跳转解析，不再因每小时 60 次限制而安装失败
- 跳跃端口范围如果包含其他协议的 UDP 端口会被拒绝，避免这些节点收不到流量
- IPv6-only VPS 的节点会自动使用 `[IPv6]` 形式生成 URI；双栈 VPS 可按协议选择 IPv4 或 IPv6
- UFW active 时，安装、添加、更改协议后自动按 TCP/UDP 放行对应端口和订阅端口
- UFW active 时，会维护脚本托管规则，端口变更后自动删除旧规则并放行新规则
- UFW active 时，删除协议会同步删除对应放行规则
- 支持一键放行所有缺失的 UFW 端口规则
- 运行管理：启动、停止、重启、状态、日志、自启、关闭自启、检查配置
- 系统工具：网络自适应优化，写入 BBR、队列算法和按内存自动取值的缓冲参数，并即时应用到网卡
- 优化前先检测内核是否支持 BBR 与 fq，不支持时自动降级为现有算法或 fq_codel，不会写入无效参数
- `net.core.default_qdisc` 只对新建网卡生效，因此会同时用 `tc` 切换在用网卡的实际队列，无需重启
- 多队列网卡保留 `mq` 根队列并逐队列设置目标算法，不牺牲多队列并行
- 状态页的队列算法在 sysctl 与网卡实际队列不一致时显示 `(未生效)`，避免误判已优化
- 优化参数写入 `/etc/sysctl.d/99-zz-sing-box-daimon.conf`，按字典序最后加载，可一键还原

## 运行目录

标准模式在 VPS 上运行后使用以下路径：

```text
/etc/sing-box/
  bin/sing-box
  conf/*.json
  cert/self.crt
  cert/self.key
  sub/sub.txt
  sub/v2rayn.txt
  sub/clash.yaml
  sub/raw.txt
  state.json
/usr/local/bin/sb
/usr/local/bin/sing-box
/etc/systemd/system/sing-box.service
/etc/systemd/system/sing-box-sub.service
```

NAT 轻量模式保留 `bin/sing-box`、VLESS 配置、状态文件和管理脚本，不会创建证书文件、`sub_server.py` 或订阅服务。Debian 使用 `/etc/systemd/system/sing-box.service`，Alpine 使用 `/etc/init.d/sing-box`。

本仓库只保存管理脚本、README 和计划文件；实际安装和运行文件由脚本在 VPS 上创建。
