#!/bin/bash
# install-wstunnel.sh — wstunnel 服务端一键安装器（独立包，与 AWG 安装器分开）
# 在一台全新的 Debian/Ubuntu 服务器上装好 wstunnel 服务端（UDP over WebSocket），
# 把 AmneziaWG 的 UDP 流量包进 TLS WebSocket（默认 443 端口）。
# 证书用 acme.sh + Cloudflare DNS-01 签发，不用开放 80/443 端口。
#
# 交互模式：直接运行，按提示输入域名、CF API Token、WS 端口、AWG 端口。
# 非交互模式：设置环境变量后运行（四个全设才跳过全部提示）：
#   DOMAIN=hkg3.nexv.me CF_TOKEN=xxx WS_PORT=443 AWG_PORT=61386
#
# 测试专用（不要在生产用）：WSTUNNEL_TEST_SKIP_ACME=1 时跳过证书签发，
# 要求证书已预先放在 /root/cert/<域名>/fullchain.pem 与 privkey.pem。
#
# 安装内容：
#   /root/wstunnel/wstunnel             wstunnel v11.1.0 二进制
#   /root/wstunnel-awg.secret           路径鉴权密钥（64 位 hex，600 权限）
#   /root/wstunnel/server.log           服务端日志
#   /root/cert/<域名>/                  证书（fullchain.pem + privkey.pem）
#   /etc/systemd/system/wstunnel.service systemd 服务（开机自启，失败自动重启）
#   /root/wstool/                       客户端一键包（linux/ + win11/）
#
# 关键约定（2026-11-23/24 生产验证，不要改）：
#   - 服务端用 CLI 旗标 --restrict-to + --restrict-http-upgrade-path-prefix，
#     不要用 --restrict-config YAML（YAML 的 !PathPrefix 在生产上从未匹配成功）。
#   - 客户端必须加 -P <密钥>（wss 地址里的路径会被忽略，升级 URI 固定是
#     /{prefix}/events，prefix 默认 v1；不加 -P 会被服务端拒绝）。
#   - AmneziaWG Windows 客户端不能用 127.0.0.1 做 Endpoint，必须用本机局域网 IP
#     （回环地址下握手永远完不成）；Win11 一键包会自动检测局域网 IP。

set -u
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

WSTUNNEL_VERSION="11.1.0"
WSTUNNEL_RELEASE="https://github.com/erebe/wstunnel/releases/download/v$WSTUNNEL_VERSION"
WSTUNNEL_DIR="/root/wstunnel"
SECRET_FILE="/root/wstunnel-awg.secret"
WSTOOL_DIR="/root/wstool"
LOCAL_FWD_PORT=61387

log() { echo "[*] $*"; }
ok() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

# run_capture <日志文件> <命令...>：运行命令，输出记入日志，返回真实退出码；
# 失败时打印日志末尾 10 行。不要用 `cmd | tail` 判断成败——管道退出码是 tail 的，
# 会把失败掩盖成成功。
run_capture() {
    local logfile=$1; shift
    "$@" >"$logfile" 2>&1
    local rc=$?
    if (( rc != 0 )); then
        warn "命令失败（退出码 $rc）：$*"
        tail -n 10 "$logfile" >&2
    fi
    return $rc
}

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash install-wstunnel.sh）"

# ---------- 系统检测 ----------
detect_os() {
    # 输出：<id> <codename>，如 debian trixie / ubuntu noble
    . /etc/os-release
    local id=${ID:-} code=${VERSION_CODENAME:-}
    case "$id:$code" in
        debian:trixie|debian:bookworm|ubuntu:noble|ubuntu:jammy) echo "$id $code" ;;
        *) die "不支持的系统：$id $code（仅支持 Debian 12/13、Ubuntu 22.04/24.04）" ;;
    esac
}

detect_arch() {
    # 输出 wstunnel 发布包用的架构名：amd64 / arm64
    case "$(uname -m)" in
        x86_64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) die "不支持的架构：$(uname -m)（仅支持 x86_64 / aarch64）" ;;
    esac
}

# ---------- 基础依赖 ----------
install_base_deps() {
    log "安装基础依赖（curl / ca-certificates / openssl / iproute2 / tar）..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt update 失败，请检查网络与软件源"
    apt-get install -y -qq curl ca-certificates openssl iproute2 tar \
        || die "基础依赖安装失败"
    ok "基础依赖就绪"
}

# ---------- 安装参数 ----------
valid_domain() {
    # 域名格式：label.label...，每段字母数字或连字符，不以连字符开头/结尾
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

pick_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        valid_domain "$DOMAIN" || die "域名格式不合法：$DOMAIN"
        return 0
    fi
    while true; do
        read -r -p "域名（客户端连接用，如 hkg3.nexv.me）： " DOMAIN
        if valid_domain "$DOMAIN"; then break; fi
        warn "域名格式不合法，请重新输入"
    done
}

pick_cf_token() {
    if [[ -n "${CF_TOKEN:-}" ]]; then return 0; fi
    while true; do
        read -r -s -p "Cloudflare API Token（需要 Zone:DNS:Edit 权限，输入时不回显）： " CF_TOKEN
        echo ""
        [[ -n "$CF_TOKEN" ]] && break
        warn "Token 不能为空，请重新输入"
    done
}

pick_ws_port() {
    if [[ -n "${WS_PORT:-}" ]]; then
        valid_port "$WS_PORT" || die "WS 端口不合法：$WS_PORT"
    else
        read -r -p "WebSocket 端口（默认 443，直接回车用默认）： " WS_PORT
        WS_PORT=${WS_PORT:-443}
        valid_port "$WS_PORT" || die "WS 端口不合法：$WS_PORT"
    fi
    # 端口占用检查（被占用时交互模式允许重输，非交互模式直接报错）
    while ss -tln "sport = :$WS_PORT" 2>/dev/null | grep -q LISTEN; do
        if (( NONINTERACTIVE == 1 )); then
            die "WS 端口 $WS_PORT 已被占用，请换一个端口"
        fi
        warn "WS 端口 $WS_PORT 已被占用"
        read -r -p "请换一个 WS 端口： " WS_PORT
        valid_port "$WS_PORT" || die "WS 端口不合法：$WS_PORT"
    done
}

pick_awg_port() {
    if [[ -n "${AWG_PORT:-}" ]]; then
        valid_port "$AWG_PORT" || die "AWG 端口不合法：$AWG_PORT"
    else
        while true; do
            read -r -p "要套用的 AWG UDP 端口（如 61386）： " AWG_PORT
            if valid_port "$AWG_PORT"; then break; fi
            warn "端口不合法，请输入 1-65535 的数字"
        done
    fi
    # 提醒：没有进程在监听这个 UDP 端口（不硬失败，AWG 可能还没装）
    if ! ss -ulnp "sport = :$AWG_PORT" 2>/dev/null | grep -q .; then
        warn "当前没有进程在监听 UDP $AWG_PORT（AWG 还没装或还没启动？装完 wstunnel 后请确认 AWG 正常运行）"
    fi
}

# ---------- DNS 检查 ----------
check_dns() {
    local pub_ip dns_ip
    # 强制 IPv4（ifconfig.me 在双栈机器上可能返回 IPv6，与 A 记录比对会误报不一致）
    pub_ip=$(curl -4 -fsSL --max-time 10 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --max-time 10 ipinfo.io/ip 2>/dev/null || true)
    # 只取 IPv4（域名同时有 AAAA 记录时 getent 可能先返回 IPv6）
    dns_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}')
    if [[ -z "$pub_ip" ]]; then
        warn "无法获取本机公网 IP，跳过域名解析检查"
        return 0
    fi
    if [[ -z "$dns_ip" ]]; then
        warn "域名 $DOMAIN 暂时解析不到任何 IP（DNS 可能还没生效）"
    elif [[ "$dns_ip" != "$pub_ip" ]]; then
        warn "域名 $DOMAIN 解析到 $dns_ip，本机公网 IP 是 $pub_ip，两者不一致"
    else
        ok "域名 $DOMAIN 已解析到本机（$pub_ip）"
        return 0
    fi
    # 解析不对：交互模式问是否继续，非交互模式只警告继续
    if (( NONINTERACTIVE == 1 )); then
        warn "非交互模式：继续安装（请确认 DNS 解析正确，否则客户端连不上）"
        return 0
    fi
    local ans
    read -r -p "是否继续安装？[y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "已取消安装"
}

# ---------- 证书（acme.sh + Cloudflare DNS-01） ----------
issue_cert() {
    local cert_dir="/root/cert/$DOMAIN"
    mkdir -p "$cert_dir"
    if [[ "${WSTUNNEL_TEST_SKIP_ACME:-0}" == "1" ]]; then
        log "测试模式：跳过 acme.sh 证书签发"
        [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]] \
            || die "测试模式要求证书已预先放在 $cert_dir/fullchain.pem 与 privkey.pem"
        ok "测试证书已就位（跳过签发）"
        return 0
    fi
    export HOME=/root
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        log "安装 acme.sh..."
        if curl -fsSL --retry 3 --retry-delay 5 -o /tmp/get-acme.sh https://get.acme.sh \
            && sh /tmp/get-acme.sh >/tmp/acme-install.log 2>&1; then
            ok "acme.sh 安装成功"
        else
            warn "get.acme.sh 安装失败，改用 git clone 方式"
            command -v git >/dev/null 2>&1 \
                || apt-get install -y -qq git >/dev/null 2>&1 || die "git 安装失败"
            rm -rf /tmp/acme.sh
            git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /tmp/acme.sh \
                >/dev/null 2>&1 || die "acme.sh 源码下载失败"
            (cd /tmp/acme.sh && ./acme.sh --install --nocron) >/tmp/acme-install.log 2>&1 \
                || die "acme.sh 安装失败"
            /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1 || true
            ok "acme.sh 安装成功（git 方式）"
        fi
        rm -f /tmp/get-acme.sh
    fi
    [[ -x /root/.acme.sh/acme.sh ]] || die "acme.sh 安装失败"
    log "用 Cloudflare DNS-01 签发证书：$DOMAIN ..."
    export CF_Token="$CF_TOKEN"
    if ! run_capture /tmp/acme-issue.log /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN"; then
        die "证书签发失败（请检查：域名是否托管在 Cloudflare、API Token 是否有 Zone:DNS:Edit 权限）"
    fi
    log "安装证书到 $cert_dir（续签后自动重启 wstunnel）..."
    if ! run_capture /tmp/acme-install-cert.log /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$cert_dir/privkey.pem" --fullchain-file "$cert_dir/fullchain.pem" \
        --reloadcmd "systemctl restart wstunnel"; then
        die "证书安装失败"
    fi
    ok "证书已签发并安装到 $cert_dir"
}

# ---------- wstunnel 二进制 ----------
install_wstunnel_binary() {
    local asset sha tmp
    asset="wstunnel_${WSTUNNEL_VERSION}_linux_${ARCH}.tar.gz"
    tmp=$(mktemp -d) || die "无法创建临时目录"
    log "下载 wstunnel v$WSTUNNEL_VERSION（$asset）..."
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/$asset" \
        "$WSTUNNEL_RELEASE/$asset" \
        || { rm -rf "$tmp"; die "wstunnel 下载失败"; }
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/checksums.txt" \
        "$WSTUNNEL_RELEASE/checksums.txt" \
        || { rm -rf "$tmp"; die "checksums.txt 下载失败"; }
    sha=$(awk -v a="$asset" '$2==a {print $1}' "$tmp/checksums.txt")
    [[ -n "$sha" ]] || { rm -rf "$tmp"; die "checksums.txt 里没有 $asset 的记录"; }
    echo "$sha  $tmp/$asset" | sha256sum -c - >/dev/null 2>&1 \
        || { rm -rf "$tmp"; die "wstunnel 安装包 sha256 校验失败"; }
    ok "sha256 校验通过"
    mkdir -p "$WSTUNNEL_DIR"
    tar --no-same-owner -xzf "$tmp/$asset" -C "$tmp" wstunnel \
        || { rm -rf "$tmp"; die "wstunnel 解压失败"; }
    install -m 755 "$tmp/wstunnel" "$WSTUNNEL_DIR/wstunnel"
    # 保存各架构哈希，供客户端包校验用
    SHA_LINUX_AMD64=$(awk -v a="wstunnel_${WSTUNNEL_VERSION}_linux_amd64.tar.gz" '$2==a {print $1}' "$tmp/checksums.txt")
    SHA_LINUX_ARM64=$(awk -v a="wstunnel_${WSTUNNEL_VERSION}_linux_arm64.tar.gz" '$2==a {print $1}' "$tmp/checksums.txt")
    SHA_WIN_AMD64=$(awk -v a="wstunnel_${WSTUNNEL_VERSION}_windows_amd64.tar.gz" '$2==a {print $1}' "$tmp/checksums.txt")
    rm -rf "$tmp"
    "$WSTUNNEL_DIR/wstunnel" --version 2>/dev/null | grep -q "$WSTUNNEL_VERSION" \
        || die "wstunnel 二进制无法运行（版本不匹配）"
    ok "wstunnel v$WSTUNNEL_VERSION 已安装到 $WSTUNNEL_DIR/wstunnel"
}

# ---------- 路径鉴权密钥 ----------
gen_secret() {
    if [[ -f "$SECRET_FILE" ]]; then
        local old
        old=$(tr -d '\n' < "$SECRET_FILE" 2>/dev/null)
        if [[ "$old" =~ ^[0-9a-f]{64}$ ]]; then
            SECRET="$old"
            ok "复用已有密钥（$SECRET_FILE，现有客户端不受影响；要轮换请先删掉该文件再重装）"
            return 0
        fi
        warn "已有密钥文件格式不对，重新生成"
    fi
    SECRET=$(openssl rand -hex 32) || die "密钥生成失败"
    printf '%s' "$SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    ok "已生成新的路径鉴权密钥"
}

# ---------- systemd 服务 ----------
write_service() {
    cat > /etc/systemd/system/wstunnel.service <<'SVC_EOF'
[Unit]
Description=wstunnel server for AmneziaWG (UDP over WebSocket)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'exec /root/wstunnel/wstunnel server --restrict-to 127.0.0.1:__AWG_PORT__ --restrict-http-upgrade-path-prefix "$(cat /root/wstunnel-awg.secret)" --tls-certificate /root/cert/__DOMAIN__/fullchain.pem --tls-private-key /root/cert/__DOMAIN__/privkey.pem wss://0.0.0.0:__WS_PORT__'
Restart=on-failure
RestartSec=5
User=root
StandardOutput=append:/root/wstunnel/server.log
StandardError=append:/root/wstunnel/server.log

[Install]
WantedBy=multi-user.target
SVC_EOF
    sed -i -e "s|__AWG_PORT__|$AWG_PORT|g" -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__WS_PORT__|$WS_PORT|g" \
        /etc/systemd/system/wstunnel.service
    ok "systemd 服务已写入"
}

# ---------- 防火墙 ----------
setup_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        warn "未安装 ufw，跳过防火墙配置（请确认云服务商安全组已放行 $WS_PORT/tcp）"
        return 0
    fi
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$WS_PORT/tcp" >/dev/null 2>&1 || warn "ufw 放行 $WS_PORT/tcp 失败，请手动检查"
        ok "ufw 已放行 $WS_PORT/tcp"
    else
        warn "ufw 未启用（inactive），未添加规则；如以后启用 ufw，请放行 $WS_PORT/tcp"
    fi
}

# ---------- 启动与验证 ----------
start_service() {
    systemctl daemon-reload
    systemctl enable wstunnel >/dev/null 2>&1 || die "服务 enable 失败"
    if ! run_capture /tmp/wstunnel-start.log systemctl restart wstunnel; then
        warn "wstunnel 服务启动失败"
        tail -n 20 "$WSTUNNEL_DIR/server.log" 2>/dev/null >&2
        die "请检查日志：$WSTUNNEL_DIR/server.log"
    fi
    sleep 2
    systemctl is-active --quiet wstunnel || die "wstunnel 服务未能保持运行"
    ss -tln "sport = :$WS_PORT" 2>/dev/null | grep -q LISTEN \
        || die "wstunnel 未在 $WS_PORT 端口监听"
    ok "wstunnel 服务运行中，监听 $WS_PORT/tcp"
}

# ---------- 客户端一键包（wstool/） ----------
# 模板用带引号的 heredoc 原样写入，再用 sed 替换 __占位符__。
# 这样模板里的 $ 变量（客户端运行时才展开）不会被安装器误展开。
gen_wstool() {
    local linux_dir="$WSTOOL_DIR/linux" win_dir="$WSTOOL_DIR/win11"
    mkdir -p "$linux_dir" "$win_dir"

    # ---- Linux 客户端一键安装脚本 ----
    cat > "$linux_dir/install-client.sh" <<'LINUX_CLIENT_EOF'
#!/bin/bash
# install-client.sh — wstunnel Linux 客户端一键安装
# 在 Linux 客户端上以 root 运行：sudo bash install-client.sh
# 作用：下载 wstunnel 二进制，装成 systemd 服务 wstunnel-client（开机自启），
# 本地监听 127.0.0.1:61387，转发到服务端 AWG 端口。
# 装完后请把 AWG 配置的 Endpoint 改成 127.0.0.1:61387，再连接。
set -u

WSTUNNEL_VERSION="__WSTUNNEL_VERSION__"
DOMAIN="__DOMAIN__"
WSS_SUFFIX="__WSS_PORT_SUFFIX__"
AWG_PORT="__AWG_PORT__"
SECRET="__SECRET__"
SHA_AMD64="__SHA_LINUX_AMD64__"
SHA_ARM64="__SHA_LINUX_ARM64__"
LOCAL_PORT=61387

[[ $EUID -eq 0 ]] || { echo "请用 root 运行（sudo bash install-client.sh）" >&2; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ASSET="wstunnel_${WSTUNNEL_VERSION}_linux_amd64.tar.gz"; SHA="$SHA_AMD64" ;;
    aarch64|arm64) ASSET="wstunnel_${WSTUNNEL_VERSION}_linux_arm64.tar.gz"; SHA="$SHA_ARM64" ;;
    *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
esac

if command -v wstunnel >/dev/null 2>&1 && wstunnel --version 2>/dev/null | grep -q "$WSTUNNEL_VERSION"; then
    echo "wstunnel $WSTUNNEL_VERSION 已安装，跳过下载"
else
    echo "下载 wstunnel v$WSTUNNEL_VERSION（$ASSET）..."
    TMP=$(mktemp -d) || { echo "无法创建临时目录" >&2; exit 1; }
    curl -fsSL --retry 3 --retry-delay 5 -o "$TMP/$ASSET" \
        "https://github.com/erebe/wstunnel/releases/download/v$WSTUNNEL_VERSION/$ASSET" \
        || { echo "下载失败" >&2; rm -rf "$TMP"; exit 1; }
    echo "$SHA  $TMP/$ASSET" | sha256sum -c - >/dev/null 2>&1 \
        || { echo "安装包 sha256 校验失败" >&2; rm -rf "$TMP"; exit 1; }
    tar --no-same-owner -xzf "$TMP/$ASSET" -C "$TMP" wstunnel \
        || { echo "解压失败" >&2; rm -rf "$TMP"; exit 1; }
    install -m 755 "$TMP/wstunnel" /usr/local/bin/wstunnel
    rm -rf "$TMP"
    echo "wstunnel 已安装到 /usr/local/bin/wstunnel"
fi

cat > /etc/systemd/system/wstunnel-client.service <<EOF
[Unit]
Description=wstunnel client for AmneziaWG
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wstunnel client -P $SECRET -L "udp://127.0.0.1:$LOCAL_PORT:127.0.0.1:$AWG_PORT" wss://$DOMAIN$WSS_SUFFIX/$SECRET
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wstunnel-client || { echo "服务启动失败" >&2; exit 1; }
sleep 1
systemctl is-active --quiet wstunnel-client || { echo "服务未能保持运行" >&2; exit 1; }
echo ""
echo "安装完成。wstunnel 客户端已在后台运行（开机自启）。"
echo "下一步：把 AWG 配置的 Endpoint 改成 127.0.0.1:$LOCAL_PORT，再连接。"
echo "查看状态：systemctl status wstunnel-client"
echo "查看日志：journalctl -u wstunnel-client -f"
LINUX_CLIENT_EOF

    # ---- Linux 客户端说明 ----
    cat > "$linux_dir/README.md" <<'LINUX_README_EOF'
# wstunnel Linux 客户端一键包

## 这是什么

把本机 AmneziaWG 客户端的 UDP 流量包进 TLS WebSocket，再发到服务端。
服务端地址：`__DOMAIN__`，WebSocket 端口：`__WS_PORT__`，对应 AWG 端口：`__AWG_PORT__`（UDP）。

## 用法

在 Linux 客户端上以 root 运行：

```bash
sudo bash install-client.sh
```

脚本会做这几件事：

1. 下载 wstunnel v__WSTUNNEL_VERSION__ 二进制（按本机架构选 amd64/arm64），校验 sha256 后装到 `/usr/local/bin/wstunnel`。
2. 创建 systemd 服务 `wstunnel-client`，开机自启，失败自动重启。
3. 本地监听 `127.0.0.1:61387`，转发到服务端 AWG 端口。

## 装完后还要做一步

把 AWG 配置（`.conf`）的 Endpoint 改成 `127.0.0.1:61387`，再连接。
注意：这个 Endpoint 是你手动改的，安装脚本不会动你的 AWG 配置。

## 常用命令

```bash
systemctl status wstunnel-client   # 查看运行状态
journalctl -u wstunnel-client -f   # 查看实时日志
systemctl restart wstunnel-client  # 重启客户端
```

## 卸载

```bash
systemctl disable --now wstunnel-client
rm -f /etc/systemd/system/wstunnel-client.service /usr/local/bin/wstunnel
systemctl daemon-reload
```

## 说明

Linux 客户端用 `127.0.0.1` 做本地转发。Windows 图形客户端有个回环地址毛病
（Endpoint 填 `127.0.0.1` 时握手永远完不成，必须用局域网 IP），Linux 内核版
AWG 没有这个问题，所以这里直接用回环地址即可。
LINUX_README_EOF

    # ---- Win11 客户端一键安装脚本 ----
    cat > "$win_dir/setup.ps1" <<'WIN_SETUP_EOF'
#Requires -RunAsAdministrator
# setup.ps1 — wstunnel Win11 客户端一键安装（请以管理员身份运行）
# 作用：
#   1. 自动检测本机局域网 IPv4 地址（AmneziaWG Windows 客户端不能用 127.0.0.1
#      做 Endpoint，必须用局域网 IP，否则握手永远完不成）
#   2. 下载 wstunnel.exe v__WSTUNNEL_VERSION__ 到脚本所在目录（校验 sha256）
#   3. 生成 start-wstunnel.bat（带 -P 路径鉴权密钥）
#   4. 创建计划任务 wstunnel-chengdu（登录时触发，后台运行，失败 1 分钟后重试）
#   5. 立即启动任务
# 重复运行会覆盖更新（幂等）。
# 装完后请把 AWG 配置的 Endpoint 改成 <局域网 IP>:61387（脚本最后会打印出来），再连接。

$ErrorActionPreference = 'Stop'

$WstunnelDir = $PSScriptRoot
$TaskName = 'wstunnel-chengdu'
$Domain = '__DOMAIN__'
$WsPortSuffix = '__WSS_PORT_SUFFIX__'
$AwgPort = __AWG_PORT__
$Secret = '__SECRET__'
$WinHash = '__SHA_WIN_AMD64__'
$Version = '__WSTUNNEL_VERSION__'
$LocalPort = 61387

# 1. 检测局域网 IP：先取默认路由的出口网卡，再取该网卡的 IPv4；取不到则退回第一个非回环、非 APIPA 地址
$lanIp = $null
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric | Select-Object -First 1
if ($route) {
    $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    if ($ip) { $lanIp = $ip.IPAddress }
}
if (-not $lanIp) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    if ($ip) { $lanIp = $ip.IPAddress }
}
if (-not $lanIp) { throw '无法检测到局域网 IPv4 地址，请确认已连接网络' }
Write-Host "检测到局域网 IP：$lanIp"

# 2. 下载 wstunnel.exe（已安装且版本一致则跳过）
$exe = Join-Path $WstunnelDir 'wstunnel.exe'
$needDownload = $true
if (Test-Path $exe) {
    $verOut = & $exe --version 2>$null
    if ($verOut -match [regex]::Escape($Version)) {
        Write-Host "wstunnel v$Version 已安装，跳过下载"
        $needDownload = $false
    }
}
if ($needDownload) {
    $asset = "wstunnel_${Version}_windows_amd64.tar.gz"
    $url = "https://github.com/erebe/wstunnel/releases/download/v$Version/$asset"
    $tgz = Join-Path $WstunnelDir $asset
    Write-Host "下载 wstunnel v$Version ..."
    Invoke-WebRequest -Uri $url -OutFile $tgz -UseBasicParsing
    $hash = (Get-FileHash -Path $tgz -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $WinHash.ToLower()) { throw 'wstunnel 安装包校验失败（sha256 不匹配）' }
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        throw '找不到 tar.exe（Win11 自带，请确认系统版本）'
    }
    tar -xzf $tgz -C $WstunnelDir
    Remove-Item $tgz -Force
    Write-Host "wstunnel.exe 已安装到 $WstunnelDir"
}

# 3. 生成 start-wstunnel.bat（ASCII 编码，cmd 对 UTF-8 BOM 支持不好）
$wssUrl = "wss://$Domain$WsPortSuffix/$Secret"
$bat = @"
@echo off
REM wstunnel client for AmneziaWG (generated by setup.ps1, do not edit -P or the URL by hand)
cd /d "$WstunnelDir"
wstunnel.exe client -P $Secret -L "udp://${lanIp}:${LocalPort}:127.0.0.1:$AwgPort" $wssUrl
"@
$batPath = Join-Path $WstunnelDir 'start-wstunnel.bat'
Set-Content -Path $batPath -Value $bat -Encoding Ascii
Write-Host "已生成 start-wstunnel.bat"

# 4. 创建计划任务（登录时触发；S4U 方式运行，不管用户是否登录都运行，不弹黑窗口；失败 1 分钟后重试，最多 3 次）
$action = New-ScheduledTaskAction -Execute $batPath
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType S4U
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除旧任务，重新创建..."
}
Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
Write-Host "计划任务 $TaskName 已创建"

# 5. 立即启动
Start-ScheduledTask -TaskName $TaskName
Write-Host ''
Write-Host '安装完成！wstunnel 已在后台运行（开机登录时自动启动，不弹窗口）。'
Write-Host "下一步：在 AmneziaWG 里把隧道的 Endpoint 改成 ${lanIp}:${LocalPort}，然后点连接。"
Write-Host '注意：如果以后局域网 IP 变了（路由器 DHCP 重新分配），请重新运行一次 setup.ps1。'
WIN_SETUP_EOF

    # ---- Win11 客户端说明 ----
    cat > "$win_dir/README.md" <<'WIN_README_EOF'
# wstunnel Win11 客户端一键包

## 这是什么

把本机 AmneziaWG 客户端的 UDP 流量包进 TLS WebSocket，再发到服务端。
服务端地址：`__DOMAIN__`，WebSocket 端口：`__WS_PORT__`，对应 AWG 端口：`__AWG_PORT__`（UDP）。

## 用法

1. 把整个 `win11` 文件夹拷到 Win11 电脑上（比如 `C:\Users\<你>\Documents\wstunnel\`）。
2. 以**管理员身份**打开 PowerShell，进入该文件夹，运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

（直接双击 `.ps1` 可能会被执行策略拦住，用上面这条命令最稳。）

脚本会做这几件事：

1. 自动检测本机局域网 IPv4 地址。
2. 下载 `wstunnel.exe` v__WSTUNNEL_VERSION__ 到当前文件夹（校验 sha256）。
3. 生成 `start-wstunnel.bat`（带路径鉴权密钥）。
4. 创建计划任务 `wstunnel-chengdu`：登录时触发，后台运行不弹窗口，失败 1 分钟后重试。
5. 立即启动任务。

重复运行 `setup.ps1` 会覆盖更新（比如局域网 IP 变了之后重跑一次即可）。

## 装完后还要做一步

在 AmneziaWG 里把隧道的 Endpoint 改成 `<局域网 IP>:61387`（脚本最后会打印检测到的 IP），然后点连接。
注意：这个 Endpoint 是你手动改的，安装脚本不会动你的 AWG 配置。

## 为什么必须用局域网 IP，不能用 127.0.0.1

AmneziaWG Windows 图形客户端有个毛病：Endpoint 填 `127.0.0.1` 时，
包能发出去、服务端也回包，但客户端收不到回包，握手永远完不成。
改成局域网 IP 就正常了。所以 `setup.ps1` 会自动检测局域网 IP 来用。

建议在路由器里给这台电脑做 DHCP 保留，固定分配同一个局域网 IP，
否则 IP 变了之后要重新运行一次 `setup.ps1`。

## 检查与排查

- 任务计划程序（`taskschd.msc`）里看 `wstunnel-chengdu` 是否在运行。
- 任务右键 → 运行，可以手动启动；右键 → 结束，可以停止。
- 如果 AmneziaWG 里发送有流量、接收一直是 0 B，先确认 Endpoint 填的是局域网 IP
  而不是 `127.0.0.1`，再确认任务正在运行。

## 卸载

在任务计划程序里删除 `wstunnel-chengdu` 任务，再删掉整个文件夹即可。
WIN_README_EOF

    # ---- 替换占位符 ----
    local wss_suffix
    if [[ "$WS_PORT" == "443" ]]; then wss_suffix=""; else wss_suffix=":$WS_PORT"; fi
    local f
    for f in "$linux_dir/install-client.sh" "$linux_dir/README.md" \
             "$win_dir/setup.ps1" "$win_dir/README.md"; do
        sed -i \
            -e "s|__WSTUNNEL_VERSION__|$WSTUNNEL_VERSION|g" \
            -e "s|__DOMAIN__|$DOMAIN|g" \
            -e "s|__WS_PORT__|$WS_PORT|g" \
            -e "s|__WSS_PORT_SUFFIX__|$wss_suffix|g" \
            -e "s|__AWG_PORT__|$AWG_PORT|g" \
            -e "s|__SECRET__|$SECRET|g" \
            -e "s|__SHA_LINUX_AMD64__|$SHA_LINUX_AMD64|g" \
            -e "s|__SHA_LINUX_ARM64__|$SHA_LINUX_ARM64|g" \
            -e "s|__SHA_WIN_AMD64__|$SHA_WIN_AMD64|g" \
            "$f"
        # 占位符必须全部替换干净，漏了就是 bug
        if grep -q "__[A-Z_]*__" "$f"; then
            die "模板替换不完整：$f 里还有未替换的占位符"
        fi
    done
    # 两个安装脚本里含密钥，600 权限（运行时用 bash / powershell 显式调用，不依赖可执行位）
    chmod 600 "$linux_dir/install-client.sh" "$win_dir/setup.ps1"
    chmod 644 "$linux_dir/README.md" "$win_dir/README.md"
    ok "客户端一键包已生成：$WSTOOL_DIR"
}

# ---------- 主流程 ----------
main() {
    echo "=============================================="
    echo "  wstunnel 服务端一键安装器（v$WSTUNNEL_VERSION）"
    echo "=============================================="
    # 四个环境变量全设才算非交互模式（缺一个就对缺的项做交互提示）
    if [[ -n "${DOMAIN:-}" && -n "${CF_TOKEN:-}" && -n "${WS_PORT:-}" && -n "${AWG_PORT:-}" ]]; then
        NONINTERACTIVE=1
    else
        NONINTERACTIVE=0
    fi
    local os_info os_id os_code
    os_info=$(detect_os) || exit 1
    os_id=${os_info%% *}; os_code=${os_info##* }
    ARCH=$(detect_arch) || exit 1
    log "系统：$os_id $os_code，架构：$ARCH"

    # 已安装检测：备份旧配置后重装（密钥复用，现有客户端不受影响）
    if [[ -f /etc/systemd/system/wstunnel.service ]]; then
        warn "检测到已有 wstunnel 安装，将备份旧配置后重新安装"
        local bk="/root/wstunnel-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$bk"
        cp -a "$SECRET_FILE" "$bk/" 2>/dev/null || true
        cp -a /etc/systemd/system/wstunnel.service "$bk/" 2>/dev/null || true
        cp -a "$WSTOOL_DIR" "$bk/" 2>/dev/null || true
        # 先 disable 再 stop：防止开机过程中旧服务在 stop 之后又被拉起来
        # （stop 之后又启动的竞态），然后等它彻底退出再继续，否则后面的
        # 端口占用检查会被旧进程拦住。
        systemctl disable --now wstunnel 2>/dev/null || true
        local i
        for i in $(seq 1 15); do
            systemctl is-active --quiet wstunnel 2>/dev/null || break
            sleep 1
        done
        ok "旧配置已备份到 $bk"
    fi

    install_base_deps

    pick_domain
    pick_cf_token
    pick_ws_port
    pick_awg_port
    log "安装参数：域名 $DOMAIN，WS 端口 $WS_PORT/tcp，AWG 端口 $AWG_PORT/udp"

    check_dns
    issue_cert
    install_wstunnel_binary
    gen_secret
    write_service
    setup_ufw
    start_service
    gen_wstool

    echo ""
    echo "=============================================="
    echo "  安装完成"
    echo "=============================================="
    echo "  服务端：wss://$DOMAIN$([ "$WS_PORT" == "443" ] || echo ":$WS_PORT")/<密钥>"
    echo "  WS 端口：$WS_PORT/tcp（TLS WebSocket）"
    echo "  AWG 端口：$AWG_PORT/udp（被套用的 UDP 端口）"
    echo "  证书：/root/cert/$DOMAIN/（acme.sh 自动续签，续完自动重启服务）"
    echo "  密钥文件：$SECRET_FILE（不要泄露，客户端包里已带上）"
    echo "  服务状态：$(systemctl is-active wstunnel)（开机自启）"
    echo "  服务日志：$WSTUNNEL_DIR/server.log"
    echo ""
    echo "  客户端一键包：$WSTOOL_DIR"
    echo "    linux/  Linux 客户端：sudo bash install-client.sh"
    echo "    win11/  Win11 客户端：管理员 PowerShell 运行 setup.ps1"
    echo ""
    echo "  下载客户端包到本地："
    echo "    scp -r root@$DOMAIN:$WSTOOL_DIR/ ./"
    echo "  （SSH 不是 22 端口时加 -P <端口>；或用你习惯的方式把 $WSTOOL_DIR 拷下来）"
    echo ""
    echo "  客户端装完后，记得把 AWG 配置的 Endpoint 改成："
    echo "    Linux：127.0.0.1:$LOCAL_FWD_PORT"
    echo "    Win11：<本机局域网 IP>:$LOCAL_FWD_PORT（setup.ps1 会打印检测到的 IP）"
    echo "=============================================="
}

# 直接执行时进入主流程；被 source 时只加载函数（供测试复用）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
