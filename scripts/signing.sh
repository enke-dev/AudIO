#!/usr/bin/env bash
# Self-signed code-signing certificate for AudIO – a stable signature keeps macOS' audio
# capture and microphone permissions across builds and updates (ad-hoc signatures change
# with every build). No Apple Developer account involved; Gatekeeper still treats the app
# as unidentified ("Open Anyway" once).
#
#   scripts/signing.sh setup   # create (or restore from 1Password) the certificate, then
#                              # store it in 1Password, set the GitHub secrets and import it
#                              # into the login keychain for local builds
#   scripts/signing.sh import  # only import from 1Password into the login keychain
#
# Needs: gh (logged in), op (signed in). Env: OP_VAULT (default: Private or Personal).
set -euo pipefail

cd "$(dirname "$0")/.."
name="AudIO Code Signing"          # certificate common name = 1Password item title
repo="enke-dev/AudIO"
openssl=/usr/bin/openssl            # LibreSSL: writes PKCS#12 the macOS keychain can import

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
p12="$work/certificate.p12"

vault() {
    if [ -n "${OP_VAULT:-}" ]; then echo "$OP_VAULT"; return; fi
    for candidate in Private Personal; do
        if op vault get "$candidate" >/dev/null 2>&1; then echo "$candidate"; return; fi
    done
    echo "error: no Private/Personal vault – set OP_VAULT" >&2; exit 1
}

# Restores certificate and password from 1Password; fails if the item doesn't exist.
restore() {
    local vault="$1"
    op item get "$name" --vault "$vault" >/dev/null 2>&1 || return 1
    op read --out-file "$p12" "op://$vault/$name/certificate.p12" >/dev/null
    password="$(op read "op://$vault/$name/password")"
    echo "Restored \"$name\" from 1Password ($vault)"
}

create() {
    local vault="$1"
    password="$($openssl rand -base64 24)"
    cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
    $openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    $openssl pkcs12 -export -name "$name" -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$p12" -passout "pass:$password"
    op item create --category password --vault "$vault" --title "$name" \
        --tags AudIO "password=$password" "certificate.p12[file]=$p12" \
        "notesPlain=Self-signed code-signing certificate for AudIO (scripts/signing.sh). Valid 10 years." >/dev/null
    echo "Created \"$name\" and stored it in 1Password ($vault)"
}

upload() {
    base64 < "$p12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$repo"
    gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$repo" --body "$password"
    echo "Set GitHub secrets MACOS_CERTIFICATE_P12 and MACOS_CERTIFICATE_PASSWORD on $repo"
}

import_keychain() {
    local keychain="$HOME/Library/Keychains/login.keychain-db"
    if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
        echo "\"$name\" is already in the login keychain"
        return
    fi
    security import "$p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
    echo "Imported \"$name\" into the login keychain – local builds use it automatically"
}

command="${1:-setup}"
vault="$(vault)"
case "$command" in
    setup)
        restore "$vault" || create "$vault"
        upload
        import_keychain
        ;;
    import)
        restore "$vault" || { echo "error: \"$name\" not found in 1Password ($vault) – run setup" >&2; exit 1; }
        import_keychain
        ;;
    *) echo "usage: $0 [setup|import]" >&2; exit 1 ;;
esac
