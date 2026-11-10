#!/bin/bash
# Imports the signing certificate into a temporary keychain of its own, for the release workflow.
# The login keychain and the keychain search list are left alone.
#
# Usage: PHOTON_SIGNING_CERTIFICATE_P12=<base64> PHOTON_SIGNING_CERTIFICATE_PASSWORD=<password> \
#          import-signing-certificate.sh <keychain-path>
#
# Prints `identity=<sha1>`. Remove the keychain afterwards with `security delete-keychain`.
set -euo pipefail

KEYCHAIN="${1:?usage: import-signing-certificate.sh <keychain-path>}"
: "${PHOTON_SIGNING_CERTIFICATE_P12:?is empty. Add the repository secret, as scripts/release/make-signing-certificate.sh explains.}"
: "${PHOTON_SIGNING_CERTIFICATE_PASSWORD:?is empty. Add the repository secret, as scripts/release/make-signing-certificate.sh explains.}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077
printf '%s' "$PHOTON_SIGNING_CERTIFICATE_P12" | base64 --decode > "$WORK/cert.p12"

# The keychain's own password only lives for this job.
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PHOTON_SIGNING_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null

# The certificate isn't trusted, so it's matched among all identities rather than only valid ones.
IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN" \
  | awk '/^ *[0-9]+\) [0-9A-F]{40} / { print $2 }' | sort -u)"
COUNT="$(printf '%s' "$IDENTITIES" | grep -c . || true)"
if [ "$COUNT" != 1 ]; then
  echo "error: expected one code-signing identity in the certificate, found $COUNT." >&2
  exit 1
fi
echo "identity=$IDENTITIES"
