#!/usr/bin/env bash
# Create a STABLE self-signed code-signing certificate for Ghostype — run ONCE on your Mac.
#
# Why: macOS ties permission grants (Accessibility, Input Monitoring, …) to the app's code
# signature. An ad-hoc signature (`codesign --sign -`) gets a fresh hash on every build, so
# macOS sees each release as a brand-new app and drops every grant — you must re-grant after
# every update. A certificate reused across releases gives a STABLE designated requirement
# (identifier + this cert), so the grants persist across updates. Free, no Apple Developer
# account needed.
#
# What this does:
#   1. Generates a self-signed code-signing certificate ("Ghostype Signing", 10-year validity)
#      in your login keychain (pre-authorizes /usr/bin/codesign so signing never prompts).
#   2. Exports the identity as a .p12 file for the CI secret (see printed next steps).
#
# After this: upload the .p12 to the repo's GitHub Actions secrets once, and every release
# build from CI is signed with it. You re-grant permissions ONE final time on the first
# cert-signed release; updates after that keep the grant.
set -euo pipefail

IDENTITY="${GHOSTYPE_SIGN_IDENTITY:-Ghostype Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OUT_P12="$HOME/Desktop/Ghostype-signing.p12"

# NOTE: no `-v` on find-identity — a self-signed cert is untrusted, so it never appears in
# the "valid identities" list, but codesign uses it fine and its designated requirement is
# still stable (identifier + certificate), which is what makes TCC grants persist.
if security find-identity -p codesigning | grep -qF "$IDENTITY"; then
    echo "==> Identity '$IDENTITY' already exists — nothing to do."
    security find-identity -p codesigning | grep -F "$IDENTITY" || true
    echo "==> If you still need the .p12 for CI, export it from Keychain Access"
    echo "    (login keychain -> '$IDENTITY' -> Export, .p12 format)."
    exit 0
fi

echo "==> Creating self-signed code-signing certificate '$IDENTITY'"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
KEY="$TMP/key.pem"; CERT="$TMP/cert.pem"; P12="$TMP/cert.p12"; CONF="$TMP/openssl.cnf"
P12_PASS="$(openssl rand -base64 18)"

# A code-signing cert: not a CA, digitalSignature + codeSigning EKU (both critical) so
# `codesign` and `security find-identity -p codesigning` recognize it. 10-year validity.
cat > "$CONF" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $IDENTITY
O = Ghostype
C = DE
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl genrsa -out "$KEY" 2048 2>/dev/null
openssl req -new -x509 -key "$KEY" -out "$CERT" -days 3650 -config "$CONF" 2>/dev/null
# `-legacy`: OpenSSL 3 defaults to AES-256/SHA-256 PKCS#12, which Apple's `security import`
# can't read. The legacy (PBE-SHA1-3DES) encoding is what the keychain accepts.
openssl pkcs12 -export -legacy -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout "pass:$P12_PASS" 2>/dev/null

# Import into the login keychain. `-T /usr/bin/codesign` pre-authorizes codesign to use the
# private key, so signing doesn't prompt.
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# Copy the .p12 somewhere durable for the one-time CI secret upload.
cp "$P12" "$OUT_P12"
chmod 600 "$OUT_P12"

echo "==> Done. Identity now available (shows as untrusted — that's expected and fine):"
security find-identity -p codesigning | grep -F "$IDENTITY" || true
cat <<EOF

Next steps (one time):
  1. The .p12 is at: $OUT_P12
  2. Base64-encode it:  base64 -i "$OUT_P12" | pbcopy
     Paste the result into a new GitHub repo secret named CODESIGN_P12_BASE64
     (repo -> Settings -> Secrets and variables -> Actions -> New repository secret).
  3. Create another secret named CODESIGN_P12_PASSWORD with this password:
       $P12_PASS
  4. Delete the .p12 from your Desktop once the secrets are saved.
  5. Keep this certificate forever — every release signed with it keeps your
     Accessibility / Input Monitoring grants. The next cert-signed release
     asks you to re-grant ONE last time; updates after that don't.

If macOS ever pops "codesign wants to sign using key…" click Always Allow.
EOF
