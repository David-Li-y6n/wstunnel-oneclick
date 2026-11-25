# 测试记录

## 静态测试（2026-11-25，沙箱，全部通过）

运行 `bash tests/test-installer.sh`，23 项全部通过：

- `install-wstunnel.sh` 通过 `bash -n` 语法检查。
- 生成的 Linux 客户端脚本 `install-client.sh` 通过 `bash -n`（443 与 8443 两组参数）。
- 两组参数下模板占位符全部替换干净，无残留。
- Linux 与 Win11 客户端脚本都带 `-P` 参数（服务端路径鉴权的硬性要求）。
- 443 时 wss 地址不带端口，8443 时带 `:8443`。
- 生成的 `wstunnel.service` 通过 `systemd-analyze verify`；
  ExecStart 确认为 CLI 双旗标 + `bash -c` 包装格式。
- `setup.ps1` 大括号/圆括号/引号平衡，here-string 成对，
  含 `Get-NetRoute` 检测、`Register-ScheduledTask`、`Start-ScheduledTask`。
- 已有证书复用（2026-11-25 新增）：`check_existing_cert` 函数存在，
  证书校验含过期检查与私钥匹配，有证书时跳过 Token 提示，
  `issue_cert` 复用时跳过签发。
- `check_existing_cert` 功能测试（真实 openssl 证书）：
  有效证书复用、错域名拒绝、过期证书拒绝、私钥不匹配拒绝、
  通配符证书覆盖子域名、缺证书目录拒绝，6 项全部通过。
  （过期证书用 Python cryptography 生成，openssl req 的 `-days` 不能为 0。）

## 容器测试（2026-11-24，Debian 13 容器，全部通过）

测试容器用 debootstrap 搭建（`tests/build-container.sh`，Debian 13 trixie，
systemd 正常启动）。因沙箱无法签发真实证书，测试用预置的自签名证书，
并用测试专用环境变量 `WSTUNNEL_TEST_SKIP_ACME=1` 跳过 acme.sh 签发步骤。
安装器以非交互模式运行（`DOMAIN=test.example.com WS_PORT=8443 AWG_PORT=61386`）。
完整日志见 `tests/container-install.log` 与 `tests/container-client-install.log`。

验证通过的项：

1. **全新安装**：系统检测（debian trixie / amd64）、基础依赖安装、DNS 不匹配警告
   （测试域名解析不对，非交互模式下警告后继续）、跳过证书签发、wstunnel 下载与
   sha256 校验、密钥生成（64 位 hex，600 权限）、服务写入、ufw 未启用分支（不崩溃，
   只打印提示）、服务启动并监听 8443/tcp、wstool 生成、安装摘要打印。
2. **重装路径**：检测到已有安装后备份旧配置（`/root/wstunnel-backup-<时间>/`），
   `disable --now` 停掉旧服务并等待退出，复用已有密钥（现有客户端不受影响），
   重装后服务正常运行。
3. **Linux 客户端安装**：在同一容器里运行生成的 `install-client.sh`，下载二进制、
   校验 sha256、创建并启动 `wstunnel-client.service`，重复运行幂等。
4. **路径鉴权正向**：带 `-P` 的客户端连接服务端，服务端日志显示
   `Tunnel accepted due to matched restriction: Allow path prefix ...`。
   （随后因容器里没有 AWG 监听 TCP 61386，出现预期的 `Connection refused`，
   不影响鉴权结论。）
5. **路径鉴权反向**：不带 `-P` 的客户端被拒绝，
   `Rejecting connection with not allowed destination`，证明鉴权确实在强制执行。
6. **生成物检查**：密钥文件 600 权限、64 位 hex；服务文件 ExecStart 与生产 S 一致
   （CLI 双旗标 + `bash -c` + `$(cat ...)` 展开）；wstool 四个文件无残留占位符，
   域名/端口/密钥替换正确；脚本 600 权限，README 644 权限。

测试中修掉的两个安装器 bug：

- DNS 检查用 `curl -4` 强制取 IPv4 公网 IP（双栈机器上 `ifconfig.me` 可能返回 IPv6，
  与 A 记录比对会误报不一致）。
- 重装时先 `disable --now` 再停旧服务并等待退出（防止开机过程中旧服务在 stop 后
  又被拉起来的竞态，以及端口占用检查被旧进程拦住）。

## 未能验证的项（诚实说明）

1. **真实证书签发**：沙箱没有真实域名与 Cloudflare API Token，acme.sh + DNS-01
   签发流程没有实际跑通过。签发命令是 acme.sh 的标准用法（`--issue --dns dns_cf`），
   但第一次在真服务器上跑时请留意签发日志。
2. **Win11 客户端实际运行**：`setup.ps1` 只做了静态检查（括号平衡、关键命令存在），
   没有在真实 Win11 上跑过。计划任务创建（S4U 登录方式、重启策略）与局域网 IP
   自动检测需要在真机上验证一次。
3. **UDP 端到端握手**：沙箱禁止所有进程的 UDP `sendto`，无法在沙箱里发 UDP 包
   触发隧道建立。路径鉴权用 TCP 隧道验证过（限制匹配逻辑与传输协议无关），
   但完整的 AWG 握手需要在真服务器 + 真客户端上验证。
4. **Linux 客户端回环地址假设**：Linux 客户端用 `127.0.0.1:61387` 做本地转发，
   依据是“回环毛病只存在于 AmneziaWG Windows 图形客户端，Linux 内核版没这个问题”。
   该假设尚未在真机上验证；如 Linux 客户端也出现只发不收的情况，改用局域网 IP 即可。

## 测试环境说明

- 容器根文件系统在 `/var/lib/wstunnel-test/debian13`（不在仓库里；
  `~/workspace` 所在的 overlay 文件系统禁止 chown，debootstrap 在里面会失败，
  所以容器只能建在 `/var/lib`）。
- 容器与宿主机共享网络命名空间，测试用 WS 端口 8443（避免与宿主机 443 冲突）。
- 容器启动用 `acs-v2/containers/boot-container.sh` 的方案（unshare + pivot_root），
  命令通过开机自启的 oneshot systemd 单元执行（沙箱禁止 nsenter 进入容器命名空间）。
