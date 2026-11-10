#!/bin/bash
# Creates Photon's long-lived self-signed code-signing certificate, once, for the release workflow.
#
# Keep using the same certificate for every release. macOS ties a granted permission, such as
# access to removable volumes, to the bundle identifier plus this certificate, so a new
# certificate makes every user grant it again. See "Distribution" in docs/PLAN.md.
#
# Usage: make-signing-certificate.sh <output-dir>
#
# The output directory must be outside any git repository, and its contents must never be
# committed. It receives:
#   photon-signing.p12         the certificate and private key, protected by a password you choose
#   photon-signing.p12.base64  the same file as base64, for the PHOTON_SIGNING_CERTIFICATE_P12 secret
#   photon-signing.cer         the public certificate alone, safe to share
#   photon-signing.sha1        its SHA-1 fingerprint, which each release's notes and log show
#
# Keep the .p12 and its password somewhere safe, such as a password manager. Losing it means a new
# certificate, and a lost permission for everyone.
set -euo pipefail

OUT="${1:?usage: make-signing-certificate.sh <output-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if git -C "$OUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $OUT is inside a git repository. Choose a directory outside it." >&2
  exit 1
fi
if [ -e "$OUT/photon-signing.p12" ]; then
  echo "error: $OUT/photon-signing.p12 already exists. Keep using it, or move it away first." >&2
  exit 1
fi

read -r -s -p "Password for the .p12: " PASSWORD; echo
read -r -s -p "Repeat it: " REPEAT; echo
if [ -z "$PASSWORD" ] || [ "$PASSWORD" != "$REPEAT" ]; then
  echo "error: the passwords are empty or don't match." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Photon Self-Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# 20 years, so it never needs replacing.
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$OUT/photon-signing.cer" 2>/dev/null

# macOS's `security import` reads only the legacy PKCS#12 algorithms. OpenSSL 3 needs -legacy for
# them, and LibreSSL, which macOS ships as `openssl`, uses them already and has no such flag.
export PHOTON_P12_PASSWORD="$PASSWORD"
if ! openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$OUT/photon-signing.cer" \
    -name "Photon Self-Signed" -out "$OUT/photon-signing.p12" -passout env:PHOTON_P12_PASSWORD 2>/dev/null; then
  openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$OUT/photon-signing.cer" \
    -name "Photon Self-Signed" -out "$OUT/photon-signing.p12" -passout env:PHOTON_P12_PASSWORD
fi
unset PHOTON_P12_PASSWORD

base64 < "$OUT/photon-signing.p12" | tr -d '\n' > "$OUT/photon-signing.p12.base64"
openssl x509 -in "$OUT/photon-signing.cer" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : \
  > "$OUT/photon-signing.sha1"

cat <<MSG
Created in $OUT. Fingerprint: $(cat "$OUT/photon-signing.sha1")

Add two repository secrets under Settings → Secrets and variables → Actions:
  PHOTON_SIGNING_CERTIFICATE_P12       the contents of photon-signing.p12.base64
  PHOTON_SIGNING_CERTIFICATE_PASSWORD  the password you just chose

Then delete photon-signing.p12.base64, and keep photon-signing.p12 and its password safe.
MSG
