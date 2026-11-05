#!/bin/bash
# Creates a throwaway self-signed code-signing certificate in a dedicated keychain. The login
# keychain and the keychain search list are left alone. Never commit the output.
# Usage: make-cert.sh <work-dir>
set -euo pipefail
WORK="${1:?work dir}"; mkdir -p "$WORK"; cd "$WORK"
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Photon Spike Self-Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
PASS=spike-only
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -passout "pass:$PASS" -name "Photon Spike Self-Signed" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -passout "pass:$PASS" -name "Photon Spike Self-Signed"
KC="$WORK/spike.keychain-db"
rm -f "$KC"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import cert.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
openssl x509 -in cert.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : > sha1.txt
echo "identity $(cat sha1.txt)"; security find-identity -p codesigning "$KC" | head -5
rm -f key.pem
