#!/bin/zsh
# One-time: creates a self-signed code-signing identity "Whopper Local Signing" in the login keychain.
# The designated requirement is pinned to this certificate, so permission grants survive rebuilds.
# Local use only (not notarized, not for distribution).
set -euo pipefail
NAME="Whopper Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already present."; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that macOS can import; Homebrew OpenSSL 3 does not.
PW="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/c.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/i.p12" -passout "pass:$PW" -name "$NAME"
security import "$T/i.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
echo "Created '$NAME'. (It shows as not trusted; codesign still uses it, which is all we need.)"
