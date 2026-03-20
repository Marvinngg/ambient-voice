#!/bin/bash
# 创建自签名代码签名证书 "WE Development"
# 用于 macOS TCC 权限在重新编译后持久化（ad-hoc 签名每次 hash 变化会丢失权限）
set -euo pipefail

CERT_NAME="WE Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 1. 检查证书是否已存在
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "证书 '$CERT_NAME' 已存在，无需重复创建"
    exit 0
fi

echo "正在创建自签名代码签名证书 '$CERT_NAME' ..."

# 2. 创建临时工作目录
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CONF="$TMPDIR/cert.conf"
KEY="$TMPDIR/key.pem"
CERT="$TMPDIR/cert.pem"
P12="$TMPDIR/cert.p12"

# 3. 生成 openssl 配置
cat > "$CONF" <<'OPENSSL_CONF'
[req]
distinguished_name = req_dn
x509_extensions = ext
prompt = no

[req_dn]
CN = WE Development

[ext]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:FALSE
OPENSSL_CONF

# 4. 生成自签名证书（有效期 10 年）
openssl req -x509 -newkey rsa:2048 \
    -keyout "$KEY" -out "$CERT" \
    -days 3650 -nodes \
    -config "$CONF" -extensions ext \
    -subj "/CN=$CERT_NAME" \
    2>/dev/null

echo "  证书已生成"

# 5. 导出为 p12 格式
# OpenSSL 3.x mishandles empty PKCS12 passwords, causing macOS `security import`
# to fail with "MAC verification failed". Use a temporary password as workaround.
# Also force legacy algorithms (3DES + SHA1) since OpenSSL 3.x defaults to
# AES-256-CBC which macOS can't read.
P12_PASS="setup-$(date +%s)"
openssl pkcs12 -export \
    -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout "pass:$P12_PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
    2>/dev/null \
|| openssl pkcs12 -export \
    -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout "pass:$P12_PASS" \
    2>/dev/null

echo "  已导出 p12"

# 6. 导入到 login keychain
security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign

echo "  已导入到 login keychain"

# 7. 信任自签名证书用于代码签名
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT"
echo "  已添加代码签名信任"

# 8. 设置 partition list（允许 codesign 无弹窗使用）
security set-key-partition-list \
    -S "apple-tool:,apple:" \
    -s -k "" \
    "$KEYCHAIN" \
    2>/dev/null || echo "  注意: set-key-partition-list 需要 keychain 密码为空或手动确认"

# 9. 验证证书
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "证书 '$CERT_NAME' 创建成功！"
    echo "现在可以使用 make run 来构建和运行（TCC 权限将跨编译持久化）"
else
    echo "错误: 证书创建后未能在 keychain 中找到"
    echo "请尝试手动检查: security find-identity -v -p codesigning"
    exit 1
fi
