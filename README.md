# record2gif

Native macOS screen recorder (QuickTime-style) that exports straight to animated GIF with a
selectable output resolution. See [SPEC.md](SPEC.md).

## Requirements

- macOS 14 or later
- Swift 5.10+ / Swift 6 toolchain

## Build & Run

```bash
# Build debug binary
make build

# Run unit tests
make test

# Build signed macOS .app bundle at build/record2gif.app
make app

# Build and launch build/record2gif.app
make run

# Clean build artifacts
make clean
```

## Screen Recording permission

macOS ties Screen Recording (TCC) grants to the app's code-signing Designated Requirement (DR). Ad-hoc signing (`codesign -s -`) produces a new CDHash on every build, causing macOS to treat each rebuild as a different binary and re-prompt for permission.

`scripts/build-app.sh` automatically signs `build/record2gif.app` with a local certificate named **`record2gif Local Signing`** when present in your keychain (or a custom identity passed via `SIGN_IDENTITY="..."`), falling back to ad-hoc signing `-` with a warning if not found.

### 1. Create a local self-signed code-signing certificate (once per machine)

```bash
TMP_CERT_DIR="$(mktemp -d)"
cat > "$TMP_CERT_DIR/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3_code_sign
prompt = no

[ dn ]
CN = record2gif Local Signing

[ v3_code_sign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_CERT_DIR/key.pem" \
  -out "$TMP_CERT_DIR/cert.pem" \
  -days 3650 \
  -config "$TMP_CERT_DIR/cert.conf"

openssl pkcs12 -export -legacy \
  -inkey "$TMP_CERT_DIR/key.pem" \
  -in "$TMP_CERT_DIR/cert.pem" \
  -out "$TMP_CERT_DIR/cert.p12" \
  -passout pass:record2gif

security import "$TMP_CERT_DIR/cert.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P record2gif \
  -T /usr/bin/codesign

rm -rf "$TMP_CERT_DIR"
```

### 2. Reset stale TCC entries and grant permission once

If macOS has cached old ad-hoc entries for `com.kkdai.record2gif`, reset them and rebuild:

```bash
tccutil reset ScreenCapture com.kkdai.record2gif
make app
open build/record2gif.app
```

Grant Screen Recording permission to `build/record2gif.app` in **System Settings → Privacy & Security → Screen Recording**. Subsequent `make app` rebuilds keep the same certificate leaf requirement (`identifier "com.kkdai.record2gif" and certificate leaf = H"..."`), so the permission persists across rebuilds.
