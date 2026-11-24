# wstunnel 一键部署包

把 AmneziaWG 的 UDP 流量包进 TLS WebSocket 的一键部署方案。
服务端一个脚本装好，客户端（Linux / Win11）各一个一键包。

适用场景：直连 UDP 被运营商干扰或封锁时，用 WebSocket（默认 443 端口，走 TLS，
流量外观看起来像普通 HTTPS）把 AWG 流量带过去。其他客户端的直连 UDP 不受影响。

```
Win11/Linux 客户端                    VPS 服务端
┌──────────────────┐     TLS WebSocket     ┌──────────────────┐
│ AmneziaWG 客户端 │ ──UDP──▶ wstunnel 客户端 │ ──wss://域名:443──▶ │ wstunnel 服务端 │ ──UDP──▶ AWG (61386)
│ Endpoint 局域网IP │  127.0.0.1:61387    │                   │  校验路径密钥   │   127.0.0.1:61386
└──────────────────┘                       └──────────────────┘
```

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `install-wstunnel.sh` | 服务端一键安装器（独立单文件 Bash，约 730 行）。在一台全新 Debian/Ubuntu 服务器上装好 wstunnel 服务端：签证书、装二进制、生成密钥、写 systemd 服务、生成客户端一键包。 |
| `README.md` | 本文件：文件说明、使用说明、部署说明、常见问题。 |
| `TESTING.md` | 测试记录：哪些验过、哪些没法在沙箱验。 |
| `tests/test-installer.sh` | 安装器测试脚本（语法检查、模板替换检查、服务文件校验）。 |
| `tests/build-container.sh` | 搭建 Debian 13 测试容器的脚本（debootstrap + systemd 启动）。 |

安装器运行后会在服务端生成（不随仓库发布，每台服务器现场生成）：

| 生成物 | 说明 |
| --- | --- |
| `/root/wstunnel/wstunnel` | wstunnel v11.1.0 二进制。 |
| `/root/wstunnel-awg.secret` | 路径鉴权密钥（64 位 hex，600 权限）。重装时复用已有密钥，现有客户端不受影响；要轮换请先删掉该文件再重装，并重新下发客户端包。 |
| `/root/wstunnel/server.log` | 服务端日志。 |
| `/root/cert/<域名>/` | 证书（`fullchain.pem` + `privkey.pem`），acme.sh 自动续签，续完自动重启服务。 |
| `/etc/systemd/system/wstunnel.service` | systemd 服务，开机自启，失败自动重启。 |
| `/root/wstool/` | 客户端一键包（现场生成，含密钥，见下）。 |

`/root/wstool/` 内容：

| 文件 | 说明 |
| --- | --- |
| `wstool/linux/install-client.sh` | Linux 客户端一键安装脚本（root 运行，装成 systemd 服务）。 |
| `wstool/linux/README.md` | Linux 客户端使用说明。 |
| `wstool/win11/setup.ps1` | Win11 客户端一键安装脚本（管理员 PowerShell 运行，自动检测局域网 IP、创建计划任务）。 |
| `wstool/win11/README.md` | Win11 客户端使用说明。 |

## 部署说明

### 环境要求

- 一台全新的 Debian 12/13 或 Ubuntu 22.04/24.04 服务器，root 权限运行安装器。
- 一个域名，已托管在 Cloudflare（DNS 由 Cloudflare 解析），并已解析到这台服务器的公网 IP。
  证书用 DNS-01 方式签发，签发过程不用开放 80/443 端口，但客户端要靠域名连进来，
  所以解析必须正确。
- 一个 Cloudflare API Token，权限需要 **Zone:DNS:Edit**（只改 DNS 就够，不用 Global API Key）。
  在 Cloudflare 控制台 → My Profile → API Tokens → Create Token → Edit zone DNS 模板，
  Zone Resources 选你的域名所在 zone。
- 服务器上已经装好 AWG 服务端并正常运行（本包只装 wstunnel，不装 AWG；
  AWG 请用 [awg-manager](https://github.com/David-Li-y6n/awg-manager) 安装）。
  安装器会问你要套用哪个 AWG UDP 端口（比如 61386）。
- 服务器能访问互联网（下载 wstunnel、acme.sh、签证书都要联网）。

### 第一步：获取代码

```bash
git clone https://github.com/David-Li-y6n/wstunnel-oneclick.git
cd wstunnel-oneclick
```

### 第二步：运行安装器

```bash
bash install-wstunnel.sh
```

安装器会一步步问你：

1. **域名**：客户端连接用的域名，如 `hkg3.nexv.me`。安装器会检查它是否解析到本机 IP，
   解析不对会提醒你确认（DNS 可能有延迟，不强制失败）。
2. **Cloudflare API Token**：输入时不回显。只在签发证书时用，不会写进任何客户端文件。
3. **WebSocket 端口**：默认 443，直接回车用默认；也可以自定义（如 8443）。
   安装器会检查端口是否被占用。非 443 端口时，客户端地址会自动带上端口号。
4. **AWG UDP 端口**：要套用的 AWG 监听端口，如 `61386`。安装器会提醒你当前有没有进程
   在监听这个 UDP 端口（没有也不强制失败，AWG 可能还没启动）。

然后安装器自动完成：签证书 → 下载并校验 wstunnel → 生成密钥 → 写 systemd 服务 →
放行防火墙 → 启动服务 → 生成客户端一键包。

### 非交互模式

四个环境变量全设就跳过全部提示（供脚本与测试使用）：

```bash
DOMAIN=hkg3.nexv.me CF_TOKEN=xxx WS_PORT=443 AWG_PORT=61386 bash install-wstunnel.sh
```

缺一个变量时，只对缺的那项做交互提示。

### 第三步：把客户端包发下去

安装完成后，客户端一键包在服务端的 `/root/wstool/`。下载下来：

```bash
scp -r root@<域名>:/root/wstool/ ./
```

（SSH 不是 22 端口时加 `-P <端口>`。）

然后：

- **Linux 客户端**：把 `wstool/linux/` 拷到客户端，`sudo bash install-client.sh`。
  装完把 AWG 配置的 Endpoint 改成 `127.0.0.1:61387`，再连接。
- **Win11 客户端**：把 `wstool/win11/` 拷到客户端，以管理员身份打开 PowerShell，
  运行 `powershell -ExecutionPolicy Bypass -File .\setup.ps1`。
  脚本会自动检测本机局域网 IP 并打印出来，装完把 AWG 配置的 Endpoint 改成
  `<局域网 IP>:61387`，再连接。

Endpoint 是手动改的，客户端一键包不会动你的 AWG 配置。

## 使用说明

### 服务端常用命令

```bash
systemctl status wstunnel          # 查看运行状态
journalctl -u wstunnel -f          # 查看实时日志（systemd）
tail -f /root/wstunnel/server.log  # 查看日志文件（wstunnel 自己的输出）
systemctl restart wstunnel         # 重启服务
```

服务端日志里 `Tunnel accepted due to matched restriction: Allow path prefix ...`
表示有客户端通过路径鉴权连上来了；`Rejecting connection` 表示有连接被拒绝
（通常是客户端没加 `-P` 或密钥不对）。

### 证书续签

acme.sh 安装时已装好自动续签（cron 任务），证书到期前会自动续签，
续完执行 `--reloadcmd "systemctl restart wstunnel"` 重启服务加载新证书。
手动检查续签状态：

```bash
/root/.acme.sh/acme.sh --list
```

### 轮换路径鉴权密钥

```bash
rm /root/wstunnel-awg.secret
bash install-wstunnel.sh   # 按提示重装，会生成新密钥
```

重装后要重新下载 `/root/wstool/` 并重新下发给客户端（旧客户端包里的密钥已失效）。
重装前旧配置会自动备份到 `/root/wstunnel-backup-<时间>/`。

### 卸载服务端

```bash
systemctl disable --now wstunnel
rm -f /etc/systemd/system/wstunnel.service
rm -rf /root/wstunnel /root/wstool /root/wstunnel-awg.secret
systemctl daemon-reload
```

证书（`/root/cert/`）和 acme.sh（`/root/.acme.sh/`）请按需自行处理；
如需彻底清除 acme.sh：`/root/.acme.sh/acme.sh --uninstall`。

## 常见问题

### 客户端连不上，服务端日志显示 Rejecting connection

最常见的原因是客户端没加 `-P` 参数。wstunnel 有个容易踩的坑：
命令行里 `wss://域名/<密钥>` 的 URL 路径会被**完全忽略**，升级请求实际发的路径是
固定格式 `/{prefix}/events`，`prefix` 来自客户端的 `-P` / `--http-upgrade-path-prefix`
参数，默认值是 `v1`。所以服务端不管怎么配路径规则，不加 `-P` 的客户端发来的都是
`/v1/events`，永远对不上密钥。本包生成的客户端脚本都已带上 `-P`，不要手动删掉。

### Win11 客户端发送有流量、接收一直是 0 B

AmneziaWG Windows 图形客户端不能用 `127.0.0.1` 做 Endpoint：
包能发到服务端、服务端也回包，但客户端收不到回包，握手永远完不成。
必须把 Endpoint 改成这台电脑的**局域网 IP**（如 `192.168.1.100:61387`）。
`setup.ps1` 会自动检测局域网 IP 并打印出来。建议在路由器里给这台电脑做 DHCP 保留，
固定分配同一个局域网 IP，否则 IP 变了之后要重新运行一次 `setup.ps1`。

Linux 客户端没有这个毛病，直接用 `127.0.0.1:61387` 即可。

### 服务端重启后 Win11 客户端连不上

wstunnel 客户端不会在服务端重启后自动重连。去任务计划程序（`taskschd.msc`）里
找到 `wstunnel-chengdu` 任务，右键 → 运行，再重新连接 AmneziaWG 即可。

### WS 端口用 443 还是自定义端口

443 最不容易被封（看起来像普通 HTTPS），优先用 443。
如果 443 已被别的服务占用（比如服务器上还跑了网站），就用自定义端口（如 8443），
客户端地址会自动带上端口号，不用手动改。

### 为什么服务端用 CLI 旗标而不用 YAML 限制配置

wstunnel v11 的 YAML 限制配置里，`!PathPrefix` 在生产上从未匹配成功过
（试过裸密钥、`.*密钥.*` 等多种正则写法都不行），而 CLI 旗标
`--restrict-to` + `--restrict-http-upgrade-path-prefix` 配合客户端 `-P` 是验证过
能正常工作的组合。所以本包固定用 CLI 旗标。

另外注意：`--restrict-to` 本身是 TCP-only 规则，UDP 隧道是靠路径前缀规则放行的，
两者缺一不可（`--restrict-to` 限定了目标地址，只允许转发到本机 AWG 端口）。

### 证书签发失败

检查三点：域名是否托管在 Cloudflare（DNS 由 Cloudflare 解析）；
API Token 是否有 Zone:DNS:Edit 权限且 Zone Resources 包含该域名；
服务器时间是否准确（证书签发对时间敏感，差太多会失败）。

### 客户端包里的密钥泄露了怎么办

按上面「轮换路径鉴权密钥」一节重新生成密钥并重新下发客户端包。
旧密钥立即失效。注意不要把 `/root/wstool/` 或密钥文件发到公开渠道。
