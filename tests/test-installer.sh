#!/bin/bash
# test-installer.sh — wstunnel 一键包静态测试（在沙箱/开发机上跑，不用容器）
# 检查项：
#   1. install-wstunnel.sh 语法（bash -n）
#   2. 生成的 Linux 客户端脚本语法（bash -n）
#   3. 模板占位符全部替换干净（443 与非 443 两组参数）
#   4. 生成的 systemd 服务文件能通过 systemd-analyze verify
#   5. PowerShell 脚本大括号/圆括号/引号平衡，here-string 成对
# 用法：bash tests/test-installer.sh（在仓库根目录运行）
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "[ok] $*"; }
fail() { FAIL=$((FAIL+1)); echo "[FAIL] $*" >&2; }

cd "$ROOT" || exit 1

# 1. 安装器语法
if bash -n install-wstunnel.sh; then pass "install-wstunnel.sh bash -n"; else fail "install-wstunnel.sh bash -n"; fi

# 生成两组测试客户端包（443 与 8443），复用安装器自身的 gen_wstool
gen_case() {
    local dir=$1 domain=$2 wsport=$3 awgport=$4
    rm -rf "$dir"
    bash -c "
        source ./install-wstunnel.sh
        WSTOOL_DIR='$dir'
        DOMAIN='$domain'
        WS_PORT='$wsport'
        AWG_PORT='$awgport'
        SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        SHA_LINUX_AMD64='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        SHA_LINUX_ARM64='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        SHA_WIN_AMD64='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        gen_wstool >/dev/null
    " || fail "gen_wstool ($domain/$wsport)"
}
gen_case /tmp/wstool-t443 test443.example.com 443 61386
gen_case /tmp/wstool-t8443 test8443.example.com 8443 51820

for d in /tmp/wstool-t443 /tmp/wstool-t8443; do
    # 2. 客户端脚本语法
    if bash -n "$d/linux/install-client.sh"; then pass "$d linux install-client.sh bash -n"; else fail "$d linux install-client.sh bash -n"; fi
    # 3. 占位符残留
    if grep -rq "__[A-Z_]*__" "$d"; then fail "$d 还有未替换的占位符"; else pass "$d 无残留占位符"; fi
    # -P 必须存在（服务端路径鉴权的硬性要求）
    if grep -q "\-P " "$d/linux/install-client.sh" && grep -q "\-P " "$d/win11/setup.ps1"; then
        pass "$d 客户端脚本都带 -P"
    else
        fail "$d 客户端脚本缺 -P"
    fi
done

# 443 时 URL 不带端口，8443 时带端口
if grep -q 'WSS_SUFFIX=""' /tmp/wstool-t443/linux/install-client.sh \
    && grep -q "WsPortSuffix = ''" /tmp/wstool-t443/win11/setup.ps1; then
    pass "443 时端口后缀为空"
else
    fail "443 时端口后缀应为空"
fi
if grep -q 'WSS_SUFFIX=":8443"' /tmp/wstool-t8443/linux/install-client.sh \
    && grep -q "WsPortSuffix = ':8443'" /tmp/wstool-t8443/win11/setup.ps1; then
    pass "8443 时端口后缀为 :8443"
else
    fail "8443 时端口后缀应为 :8443"
fi

# 4. 服务文件生成 + systemd-analyze verify
bash -c "
    source ./install-wstunnel.sh
    DOMAIN=svc.example.com WS_PORT=443 AWG_PORT=61386 write_service >/dev/null
"
if systemd-analyze verify /etc/systemd/system/wstunnel.service >/dev/null 2>&1; then
    pass "wstunnel.service 通过 systemd-analyze verify"
else
    fail "wstunnel.service 未通过 systemd-analyze verify"
fi
if grep -q "bash -c 'exec /root/wstunnel/wstunnel server --restrict-to 127.0.0.1:61386 --restrict-http-upgrade-path-prefix" \
    /etc/systemd/system/wstunnel.service; then
    pass "ExecStart 为 CLI 双旗标 + bash -c 包装"
else
    fail "ExecStart 不是预期的 CLI 双旗标格式"
fi
rm -f /etc/systemd/system/wstunnel.service

# 5. PowerShell 平衡检查
if python3 - <<'PYEOF'
import sys
s = open('/tmp/wstool-t443/win11/setup.ps1').read()
checks = [
    ('大括号', s.count('{') == s.count('}')),
    ('圆括号', s.count('(') == s.count(')')),
    ('双引号偶数', s.count('"') % 2 == 0),
    ('here-string 成对', s.count('@"') == s.count('"@') == 1),
    ('含 Get-NetRoute 检测', 'Get-NetRoute' in s),
    ('含 Register-ScheduledTask', 'Register-ScheduledTask' in s),
    ('含 Start-ScheduledTask', 'Start-ScheduledTask' in s),
]
bad = [name for name, ok in checks if not ok]
if bad:
    print('setup.ps1 检查失败：' + ', '.join(bad), file=sys.stderr)
    sys.exit(1)
PYEOF
then
    pass "setup.ps1 平衡与关键命令检查"
else
    fail "setup.ps1 平衡与关键命令检查"
fi

echo ""
echo "通过：$PASS，失败：$FAIL"
[[ $FAIL -eq 0 ]]
