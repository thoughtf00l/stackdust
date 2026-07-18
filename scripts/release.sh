#!/bin/bash
# Release Stackdust: bump the version, build, package (zip + DMG), sign the
# Sparkle update, refresh the appcast, publish the GitHub release, and bump
# the Homebrew cask.
#
# Usage: scripts/release.sh <version> [--notes "text"] [--dry-run]
#   --notes    release notes (one paragraph); also shown in Sparkle's update dialog
#   --dry-run  bump, build, and package only — then revert the bump; nothing is
#              committed, pushed, or published
#
# The Sparkle EdDSA private key must be in the login Keychain (generate_keys).
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

VERSION="${1:?usage: scripts/release.sh <version> [--notes text] [--dry-run]}"
shift
NOTES="Bug fixes and improvements."
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 2; }

if [ "$DRY_RUN" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty; commit or stash first" >&2
    exit 2
fi

PBXPROJ=Stackdust.xcodeproj/project.pbxproj
APPCAST=docs/appcast.xml
TEAM=LB2P67XHCM
REPO=thoughtf00l/stackdust
TAP_DIR="$HOME/dev/homebrew-tap"
SPARKLE_VERSION=2.9.4
TOOLS=.build/release-tools

# --- tooling (cached under .build) ------------------------------------------
SPARKLE_BIN="$TOOLS/sparkle-$SPARKLE_VERSION/bin"
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "==> Fetching Sparkle $SPARKLE_VERSION tools"
    mkdir -p "$TOOLS/sparkle-$SPARKLE_VERSION"
    curl -fsSL -o "$TOOLS/sparkle.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    tar -xf "$TOOLS/sparkle.tar.xz" -C "$TOOLS/sparkle-$SPARKLE_VERSION"
    rm "$TOOLS/sparkle.tar.xz"
fi

VENV="$TOOLS/venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "==> Installing dmgbuild into $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" -q install dmgbuild
fi

# --- bump + build -------------------------------------------------------------
echo "==> Bumping version to $VERSION"
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"

restore_bump() { git checkout -- "$PBXPROJ"; }
[ "$DRY_RUN" -eq 1 ] && trap restore_bump EXIT

echo "==> Building Release"
xcodebuild -project Stackdust.xcodeproj -scheme Stackdust -configuration Release \
    -derivedDataPath .build/xcode build

APP=.build/xcode/Build/Products/Release/Stackdust.app

# --- verify before packaging --------------------------------------------------
echo "==> Verifying $APP"
# PlistBuddy, not `defaults read`: cfprefsd caches plists by path and can serve
# stale values for rebuilt bundles.
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
short=$(plist CFBundleShortVersionString)
bundle_version=$(plist CFBundleVersion)
feed=$(plist SUFeedURL)
ed_key=$(plist SUPublicEDKey)
[ "$short" = "$VERSION" ] || { echo "CFBundleShortVersionString is $short, expected $VERSION" >&2; exit 1; }
[ "$bundle_version" = "$VERSION" ] || { echo "CFBundleVersion is $bundle_version, expected $VERSION" >&2; exit 1; }
[ -n "$feed" ] && [ -n "$ed_key" ] || { echo "Sparkle keys missing from Info.plist" >&2; exit 1; }
# capture instead of piping into grep: pipefail turns grep -q's early exit
# (SIGPIPE to codesign) into a spurious failure
signature=$(codesign -dv "$APP" 2>&1)
case "$signature" in
    *"TeamIdentifier=$TEAM"*) ;;
    *) echo "app is not signed by team $TEAM:" >&2; echo "$signature" >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$APP" || { echo "code signature verification failed" >&2; exit 1; }

# --- package ------------------------------------------------------------------
DIST=.build/dist
rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/Stackdust-$VERSION.zip"
DMG="$DIST/Stackdust-$VERSION.dmg"

echo "==> Packaging $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Packaging $DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg_settings.py -D app="$APP" Stackdust "$DMG"

echo "==> Signing the update"
SIG_ATTRS=$("$SPARKLE_BIN/sign_update" "$ZIP")
ZIP_URL="https://github.com/$REPO/releases/download/v$VERSION/Stackdust-$VERSION.zip"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> Dry run: appcast item that would be added to $APPCAST:"
    python3 scripts/update_appcast.py "$APPCAST" --version "$VERSION" --url "$ZIP_URL" \
        --signature-attrs "$SIG_ATTRS" --notes "$NOTES" --print-only
    echo "==> Dry run: artifacts left in $DIST; no commit, no release"
    exit 0
fi

echo "==> Updating $APPCAST"
python3 scripts/update_appcast.py "$APPCAST" --version "$VERSION" --url "$ZIP_URL" \
    --signature-attrs "$SIG_ATTRS" --notes "$NOTES"

# --- publish ------------------------------------------------------------------
echo "==> Committing and publishing v$VERSION"
git add "$PBXPROJ" "$APPCAST"
git commit -m "Release $VERSION"
git push
gh release create "v$VERSION" "$ZIP" "$DMG" --title "Stackdust $VERSION" --notes "$NOTES"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

# --- Homebrew cask ------------------------------------------------------------
CASK="$TAP_DIR/Casks/stackdust.rb"
if [ -f "$CASK" ]; then
    echo "==> Bumping Homebrew cask"
    sed -i '' -e "s/version \"[^\"]*\"/version \"$VERSION\"/" \
              -e "s/sha256 \"[^\"]*\"/sha256 \"$SHA\"/" "$CASK"
    git -C "$TAP_DIR" add Casks/stackdust.rb
    git -C "$TAP_DIR" commit -m "stackdust $VERSION"
    git -C "$TAP_DIR" push

    echo "==> End-to-end check: re-downloading the release asset"
    got=$(curl -fsSL "$ZIP_URL" | shasum -a 256 | cut -d' ' -f1)
    [ "$got" = "$SHA" ] || { echo "sha256 mismatch: asset $got vs cask $SHA" >&2; exit 5; }
else
    echo "note: $CASK not found; update the cask manually (sha256 $SHA)" >&2
fi

echo "==> Done: v$VERSION released (sha256 $SHA)"
echo "    Remember to push the site (docs/) if Pages deploys from a branch."
