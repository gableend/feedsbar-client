#!/usr/bin/env bash
#
# scripts/release.sh — one-shot release pipeline for FeedsBar.
#
# Does, in order:
#   1. archive the Release config with the Developer ID signing chain
#   2. export the archive as a signed, hardened-runtime .app
#   3. package the .app into a DMG (drag-to-Applications, no branded bg yet)
#   4. notarize the DMG with Apple (--wait blocks for the round-trip)
#   5. staple the notarization ticket onto the DMG
#   6. validate the staple and print the final DMG path
#
# Prerequisites (Phase 0 of the distribution plan):
#   - Developer ID Application cert installed in login keychain
#   - notarytool profile named "feedsbar" stored in keychain:
#       xcrun notarytool store-credentials "feedsbar" \
#         --apple-id you@example.com --team-id HKFGXYWVCQ --password app-spec-pw
#
# Usage:
#   ./scripts/release.sh                         # reads version from project
#   VERSION=1.0.1 ./scripts/release.sh           # override marketing version
#   SKIP_NOTARIZE=1 ./scripts/release.sh         # dry-run: archive + DMG only
#   NOTARY_PROFILE=other ./scripts/release.sh    # alternate keychain profile
#
# Output lands in ./build/release/ at the repo root:
#   build/release/FeedsBar-<version>.dmg
#   build/release/FeedsBarClient.xcarchive (retained for dSYM symbolication)

set -euo pipefail

# ----------------------------------------------------------------------------
# Colours for readability in the terminal
# ----------------------------------------------------------------------------
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
DIM=$'\033[2m'
RESET=$'\033[0m'

step()  { printf '\n%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
info()  { printf '%s  - %s%s\n' "$DIM" "$*" "$RESET"; }
ok()    { printf '%s  ✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn()  { printf '%s  ! %s%s\n' "$YELLOW" "$*" "$RESET"; }
die()   { printf '%s  ✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Locate repo + project
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/FeedsBarClient"
PROJECT="$PROJECT_DIR/FeedsBarClient.xcodeproj"
SCHEME="FeedsBarClient"
APP_NAME="FeedsBarClient"
PRODUCT_NAME="FeedsBar"  # user-facing name on the DMG + volume label
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
BUILD_DIR="$REPO_ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

NOTARY_PROFILE="${NOTARY_PROFILE:-feedsbar}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

# Derive version from the project if not passed explicitly. We use xcodebuild
# -showBuildSettings rather than parsing pbxproj directly so the source of
# truth stays the Xcode project.
if [[ -z "${VERSION:-}" ]]; then
    step "Reading version from project"
    VERSION=$(
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings -configuration Release 2>/dev/null \
        | awk '/ MARKETING_VERSION = /{print $3; exit}'
    )
    [[ -n "$VERSION" ]] || die "Could not read MARKETING_VERSION from project"
    info "MARKETING_VERSION=$VERSION"
fi

DMG_PATH="$BUILD_DIR/${PRODUCT_NAME}-${VERSION}.dmg"

# ----------------------------------------------------------------------------
# Pre-flight: toolchain + credentials
# ----------------------------------------------------------------------------
step "Pre-flight checks"

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"
command -v xcrun >/dev/null      || die "xcrun not found — install Xcode CLT"
command -v hdiutil >/dev/null    || die "hdiutil not found — macOS only"

# Developer ID cert present?
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "Developer ID Application:"; then
    die "No 'Developer ID Application' cert in login keychain. Create one at developer.apple.com and import it."
fi
ok "Developer ID Application cert found"

# notarytool profile present?
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        die "notarytool keychain profile '$NOTARY_PROFILE' not found. Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id … --team-id HKFGXYWVCQ --password …"
    fi
    ok "notarytool profile '$NOTARY_PROFILE' accessible"
else
    warn "SKIP_NOTARIZE=1 — will archive + export + DMG only"
fi

# ----------------------------------------------------------------------------
# Clean previous output
# ----------------------------------------------------------------------------
step "Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ok "fresh build dir"

# ----------------------------------------------------------------------------
# Archive
# ----------------------------------------------------------------------------
step "Archiving $SCHEME (Release) — version $VERSION"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    | sed 's/^/    /' || die "archive failed"
ok "archive built: $ARCHIVE_PATH"

# ----------------------------------------------------------------------------
# Export as Developer ID
# ----------------------------------------------------------------------------
step "Exporting archive as Developer ID"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet \
    | sed 's/^/    /' || die "export failed"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || die "exported .app not found at $APP_PATH"
ok "exported: $APP_PATH"

# Quick post-export sanity: the binary must advertise Developer ID in its
# authority chain, otherwise notarization will reject it with a cryptic error.
#
# Buffer the output first rather than piping straight into grep -q. grep -q
# closes its read end as soon as it matches, codesign gets SIGPIPE, pipefail
# propagates the non-zero exit, and the `!` flips it into a false-negative
# failure. Annoying bash gotcha; the buffer sidesteps it entirely.
CODESIGN_INFO=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)
if ! grep -q "Authority=Developer ID Application:" <<<"$CODESIGN_INFO"; then
    die "exported app isn't signed with Developer ID — check Release config in project.pbxproj"
fi
ok "signed by Developer ID Application"

# ----------------------------------------------------------------------------
# DMG
# ----------------------------------------------------------------------------
step "Creating DMG"

# Staging directory so the DMG contains just the app + /Applications symlink
# (so the user can drag straight into Applications from the mounted image).
STAGE_DIR="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/$PRODUCT_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$PRODUCT_NAME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    >/dev/null || die "hdiutil failed"

rm -rf "$STAGE_DIR"
ok "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"

# ----------------------------------------------------------------------------
# Notarize + staple
# ----------------------------------------------------------------------------
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    warn "Skipping notarization (SKIP_NOTARIZE=1)"
    step "Done (unnotarized)"
    info "spctl will reject this DMG as 'Unnotarized Developer ID' — fine for local testing, not for distribution."
    info "Final DMG: $DMG_PATH"
    exit 0
fi

step "Submitting for notarization (this blocks 5–30 min)"
info "Profile: $NOTARY_PROFILE"

# Submit + poll separately so a transient DNS/network blip during the wait
# phase doesn't lose an otherwise-good submission. Without this split we hit
# NSURLErrorDomain -1003 on the first run and wrongly treated an in-progress
# submission as a failure.
#
# Step A: submit, capture the submission id.
SUBMIT_OUTPUT=$(mktemp)
if ! xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --output-format json \
        2>&1 | tee "$SUBMIT_OUTPUT"; then
    rm -f "$SUBMIT_OUTPUT"
    die "notarytool submit failed — check network / credentials and re-run"
fi
SUB_ID=$(grep -oE '"id": *"[0-9a-f-]+"' "$SUBMIT_OUTPUT" | head -1 | awk -F'"' '{print $4}')
rm -f "$SUBMIT_OUTPUT"
[[ -n "$SUB_ID" ]] || die "couldn't parse submission id from notarytool output"
ok "Submitted (id=$SUB_ID) — polling Apple for status"

# Step B: poll until the status settles. Tolerates transient lookup errors
# by retrying; if Apple's status API is down we keep trying every 30s until
# the overall MAX_WAIT_MIN elapses.
POLL_INTERVAL=30
MAX_WAIT_MIN=30
DEADLINE=$(( $(date +%s) + MAX_WAIT_MIN * 60 ))
STATUS=""
while true; do
    if [[ $(date +%s) -gt $DEADLINE ]]; then
        die "Notarization still in progress after ${MAX_WAIT_MIN}m — resume with: xcrun notarytool wait $SUB_ID --keychain-profile $NOTARY_PROFILE"
    fi
    INFO=$(xcrun notarytool info "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true)
    STATUS=$(echo "$INFO" | awk '/^  status: /{print $2; exit}')
    case "$STATUS" in
        Accepted) break ;;
        Invalid|Rejected) break ;;
        "In Progress"|"")
            info "Status: ${STATUS:-transient error} — checking again in ${POLL_INTERVAL}s"
            sleep "$POLL_INTERVAL"
            ;;
        *)
            info "Unexpected status '$STATUS' — retrying"
            sleep "$POLL_INTERVAL"
            ;;
    esac
done

if [[ "$STATUS" != "Accepted" ]]; then
    warn "Notarization status: $STATUS (id=$SUB_ID)"
    warn "Apple's log:"
    xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
    die "Notarization failed"
fi
ok "Notarization accepted (id=$SUB_ID)"

step "Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH" || die "stapler staple failed"
xcrun stapler validate "$DMG_PATH" || die "stapler validate failed"
ok "Staple verified"

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
step "Release ready"
echo
echo "  Version:  $VERSION"
echo "  DMG:      $DMG_PATH"
echo "  Archive:  $ARCHIVE_PATH  (keep for dSYM symbolication)"
echo
info "Verify on another Mac:"
info "  1. Copy $DMG_PATH"
info "  2. Double-click, drag FeedsBar to Applications"
info "  3. Launch — should open with zero Gatekeeper warnings"
