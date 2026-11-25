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
    ('含自动重连循环', ':loop' in s and 'goto loop' in s),
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

# 6. 已有证书复用（静态检查）
if grep -q "check_existing_cert" install-wstunnel.sh; then pass "含 check_existing_cert 函数"; else fail "缺 check_existing_cert 函数"; fi
if grep -q "WSTUNNEL_CERT_DIR" install-wstunnel.sh; then pass "证书根目录可用 WSTUNNEL_CERT_DIR 覆盖（供测试）"; else fail "证书根目录不可覆盖"; fi
if grep -q "openssl x509 -noout -checkend" install-wstunnel.sh && grep -q "openssl pkey -in" install-wstunnel.sh; then
    pass "证书校验含过期检查与私钥匹配"
else
    fail "证书校验不完整（缺过期检查或私钥匹配）"
fi
if grep -q "使用已有证书，跳过 Cloudflare API Token" install-wstunnel.sh; then
    pass "有证书时跳过 Token 提示"
else
    fail "有证书时未跳过 Token 提示"
fi
if grep -q "USE_EXISTING_CERT == 1" install-wstunnel.sh; then pass "issue_cert 复用时跳过签发"; else fail "issue_cert 未跳过签发"; fi

# 7. check_existing_cert 功能测试（真实 openssl 证书）
CERT_TEST_DIR=$(mktemp -d)
cert_case() {
    # cert_case <域名目录> <SAN/CN> <有效天数> <key来源 ok|other>：生成一对证书+私钥
    local domain=$1 san=$2 days=$3 key_src=$4
    local d="$CERT_TEST_DIR/$domain"
    mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -keyout "$d/privkey.pem" -out "$d/fullchain.pem" \
        -days "$days" -nodes -subj "/CN=$san" \
        -addext "subjectAltName=DNS:$san" >/dev/null 2>&1 \
        || fail "生成测试证书失败：$domain"
    if [[ "$key_src" == "other" ]]; then
        # 用另一把密钥替换私钥（模拟证书与私钥不匹配）
        openssl genrsa -out "$d/privkey.pem" 2048 >/dev/null 2>&1
    fi
}
cert_case test.example.com test.example.com 30 ok
cert_case wrong.example.com other.example.com 30 ok
cert_case mismatch.example.com mismatch.example.com 30 other
cert_case sub.example.com "*.example.com" 30 ok
# 过期证书：openssl req 的 -days 不能为 0/负数，用 Python 生成一张 2020 年就过期的证书
expired_dir="$CERT_TEST_DIR/expired.example.com"
mkdir -p "$expired_dir"
python3 - "$expired_dir" <<'PYEOF' || fail "生成过期测试证书失败"
import sys
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from datetime import datetime
d = sys.argv[1]
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "expired.example.com")])
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(datetime(2020, 1, 1)).not_valid_after(datetime(2020, 1, 2))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("expired.example.com")]), critical=False)
        .sign(key, hashes.SHA256()))
open(d + "/fullchain.pem", "wb").write(cert.public_bytes(serialization.Encoding.PEM))
open(d + "/privkey.pem", "wb").write(key.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
    serialization.NoEncryption()))
PYEOF
check_cert() {
    # check_cert <域名> <期望 1/0>：调用 check_existing_cert 并比对 USE_EXISTING_CERT
    local domain=$1 expect=$2 got
    got=$(bash -c "
        source ./install-wstunnel.sh
        WSTUNNEL_CERT_DIR='$CERT_TEST_DIR'
        DOMAIN='$domain'
        check_existing_cert >/dev/null 2>&1
        echo \$USE_EXISTING_CERT
    ")
    if [[ "$got" == "$expect" ]]; then pass "check_existing_cert $domain -> $expect"; else fail "check_existing_cert $domain 应为 $expect，实际 $got"; fi
}
check_cert test.example.com 1
check_cert wrong.example.com 0
check_cert expired.example.com 0
check_cert mismatch.example.com 0
check_cert sub.example.com 1
check_cert missing.example.com 0
rm -rf "$CERT_TEST_DIR"

echo ""
echo "通过：$PASS，失败：$FAIL"
[[ $FAIL -eq 0 ]]
