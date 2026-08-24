#!/bin/bash
set -euo pipefail

# Release script for growlrrr
# Creates a distributable archive of the app bundle

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"

# Load .env (not committed) for signing config: TEAM_NAME, TEAM_ID,
# SELF_SIGN_IDENTITY. In CI these come from the environment/secrets instead.
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi

# Use the provided version (CI passes the tag), or derive one from git
VERSION="${1:-$(git -C "$PROJECT_DIR" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"

if [[ -z "$VERSION" ]]; then
    echo "Error: Could not determine version"
    exit 1
fi

echo "Building growlrrr v$VERSION for release..."

# Build release bundle (signs with Developer ID if TEAM_NAME/TEAM_ID env vars set).
# bundle.sh stamps $VERSION into the bundle's Info.plist, which is where the
# binary's --version comes from.
VERSION="$VERSION" "$SCRIPT_DIR/bundle.sh" release

APP_BUNDLE="$BUILD_DIR/release/growlrrr.app"

# Re-sign with a stable self-signed identity when no Developer ID is configured.
#
# bundle.sh signs with "Developer ID Application: ..." if TEAM_NAME/TEAM_ID are
# set, otherwise it falls back to ad-hoc ("-"). Ad-hoc signatures have no stable
# identity, so Gatekeeper/keychain trust and TCC permission grants don't persist
# across rebuilds. A named self-signed certificate gives the app a consistent
# signing identity between releases without needing an Apple Developer account.
#
# Set SELF_SIGN_IDENTITY (in .env or the environment) to the common name of a
# self-signed code-signing certificate. If it doesn't exist in the keychain yet,
# we create one. This only runs when TEAM_NAME/TEAM_ID are absent -- a real
# Developer ID always takes precedence.
if [[ -z "${TEAM_NAME:-}" || -z "${TEAM_ID:-}" ]] && [[ -n "${SELF_SIGN_IDENTITY:-}" ]]; then
    echo ""
    echo "Signing with self-signed identity: $SELF_SIGN_IDENTITY"

    # Create the self-signed code-signing certificate if it's not already in a
    # keychain. `security find-identity -v -p codesigning` lists valid
    # code-signing identities; we match on the common name.
    if ! security find-identity -v -p codesigning | grep -qF "$SELF_SIGN_IDENTITY"; then
        echo "Certificate not found; creating self-signed certificate..."

        # certificate.pl ships with the codesigning tools; if it's unavailable
        # we build the cert with a scripted Certificate Assistant request.
        CERT_TMP="$(mktemp -d)"
        trap 'rm -rf "$CERT_TMP"' EXIT

        # OpenSSL config for a self-signed cert with the codeSigning EKU.
        cat > "$CERT_TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $SELF_SIGN_IDENTITY
[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$CERT_TMP/key.pem" \
            -out "$CERT_TMP/cert.pem" \
            -days 3650 \
            -config "$CERT_TMP/cert.cnf"

        # Bundle key + cert into a PKCS#12 for import (empty passphrase).
        openssl pkcs12 -export \
            -inkey "$CERT_TMP/key.pem" \
            -in "$CERT_TMP/cert.pem" \
            -out "$CERT_TMP/cert.p12" \
            -passout pass:

        # Import into the login keychain. -T authorises codesign to use the key
        # without an interactive prompt on each signing.
        LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
        security import "$CERT_TMP/cert.p12" \
            -k "$LOGIN_KEYCHAIN" \
            -P "" \
            -T /usr/bin/codesign

        # Trust the cert for code signing so Gatekeeper accepts it locally.
        sudo security add-trusted-cert -d \
            -r trustAsRoot \
            -p codeSign \
            -k /Library/Keychains/System.keychain \
            "$CERT_TMP/cert.pem" || \
            echo "  WARNING: could not add cert to system trust (continuing)"

        rm -rf "$CERT_TMP"
        trap - EXIT
    fi

    # Re-sign the bundle with the named self-signed identity. Same options as a
    # Developer ID sign so the resulting bundle is structured consistently;
    # hardened runtime is fine for local/self-signed distribution.
    codesign --force --deep \
        --options runtime \
        --sign "$SELF_SIGN_IDENTITY" \
        "$APP_BUNDLE"

    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    echo "Self-signed signing complete."
fi

# Notarize if credentials are available, otherwise skip (e.g. for source builds).
if [[ -n "${TEAM_ID:-}" && -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    echo ""
    echo "Notarizing app bundle..."
    ZIP_FOR_NOTARY="$BUILD_DIR/release/growlrrr-notary.zip"

    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

    rm -f "$ZIP_FOR_NOTARY"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_FOR_NOTARY"

    xcrun notarytool submit "$ZIP_FOR_NOTARY" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    rm -f "$ZIP_FOR_NOTARY"
    echo "Notarization complete."
else
    echo "Skipping notarization (APPLE_ID / APPLE_APP_PASSWORD / TEAM_ID not set)."
fi

# Create dist directory
mkdir -p "$DIST_DIR"

# Create archive
ARCHIVE_NAME="growlrrr-${VERSION}-macos.tar.gz"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

echo ""
echo "Creating archive: $ARCHIVE_NAME"

# Create tarball from the release directory
cd "$BUILD_DIR/release"
tar -czf "$ARCHIVE_PATH" growlrrr.app

# Calculate SHA256
SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)

echo ""
echo "=== Release Build Complete ==="
echo "Archive: $ARCHIVE_PATH"
echo "SHA256:  $SHA256"
echo ""
echo "To create a GitHub release:"
echo "  gh release create v$VERSION $ARCHIVE_PATH --title \"v$VERSION\" --notes \"Release v$VERSION\""
echo ""
echo "Homebrew formula URL (after release):"
echo "  https://github.com/moltenbits/growlrrr/releases/download/v$VERSION/$ARCHIVE_NAME"
echo ""

# Output for CI
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "archive_path=$ARCHIVE_PATH" >> "$GITHUB_OUTPUT"
    echo "archive_name=$ARCHIVE_NAME" >> "$GITHUB_OUTPUT"
    echo "sha256=$SHA256" >> "$GITHUB_OUTPUT"
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
