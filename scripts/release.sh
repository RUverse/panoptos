#!/bin/bash
#
# Builds a signed, notarized, stapled Panoptos.dmg and matching corresponding
# source for an immutable GitHub release, then prepares the existing Sparkle
# feed for later website publication.
#
# The app and the disk image are notarized separately and on purpose. Stapling
# the app means it still passes Gatekeeper after the user drags it out of the
# image, and stapling the image means the download itself opens without a
# warning. Notarizing only the image would leave the copied app relying on a
# network check that fails offline.
#
# Usage:
#   scripts/release.sh --release-notes PATH --github-repository OWNER/REPO
#                                   build, notarize, staple, verify, and stage
#   scripts/release.sh --dry-run    build, verify signing, and produce an
#                                   unnotarized image for inspection; no upload
#
# Requires the "panoptos-notary" keychain profile created by
# `xcrun notarytool store-credentials`.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  scripts/release.sh --release-notes PATH --github-repository OWNER/REPO
  scripts/release.sh --dry-run

Options:
  --release-notes PATH  Non-empty Markdown release notes to embed in the
                        generated Sparkle appcast. Required outside dry runs.
  --github-repository OWNER/REPO
                        Canonical repository used for immutable asset URLs.
                        Required outside dry runs.
  --dry-run             Archive, export, audit signing, and build an unsigned,
                        unnotarized Panoptos.dmg for local inspection without
                        staging website files.
  -h, --help            Show this help.

The normal command prepares GitHub release assets and stages only appcast.xml
in the website checkout. It never creates a tag, release, commit, or push.
USAGE
}

argument_error() {
    printf 'error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

DRY_RUN=false
RELEASE_NOTES_INPUT=""
GITHUB_REPOSITORY=""

while (( $# > 0 )); do
    case "$1" in
        --dry-run)
            [[ "$DRY_RUN" == false ]] || argument_error "--dry-run may be supplied only once"
            DRY_RUN=true
            ;;
        --release-notes)
            [[ -z "$RELEASE_NOTES_INPUT" ]] \
                || argument_error "--release-notes may be supplied only once"
            (( $# >= 2 )) || argument_error "--release-notes requires a path"
            [[ -n "$2" && "$2" != -* ]] \
                || argument_error "--release-notes requires a path"
            RELEASE_NOTES_INPUT="$2"
            shift
            ;;
        --github-repository)
            [[ -z "$GITHUB_REPOSITORY" ]] \
                || argument_error "--github-repository may be supplied only once"
            (( $# >= 2 )) || argument_error "--github-repository requires OWNER/REPO"
            GITHUB_REPOSITORY="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            argument_error "unknown option: $1"
            ;;
    esac
    shift
done

if [[ "$DRY_RUN" == false && -z "$RELEASE_NOTES_INPUT" ]]; then
    argument_error "--release-notes is required outside a dry run"
fi
if [[ "$DRY_RUN" == false && ! "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    argument_error "--github-repository must be a canonical OWNER/REPO outside a dry run"
fi

if [[ -n "$RELEASE_NOTES_INPUT" ]]; then
    [[ -f "$RELEASE_NOTES_INPUT" ]] \
        || argument_error "release notes file does not exist: $RELEASE_NOTES_INPUT"
    [[ -s "$RELEASE_NOTES_INPUT" ]] \
        || argument_error "release notes file is empty: $RELEASE_NOTES_INPUT"
    RELEASE_NOTES=$(cd "$(dirname "$RELEASE_NOTES_INPUT")" && pwd -P)/$(basename "$RELEASE_NOTES_INPUT")
else
    RELEASE_NOTES=""
fi

readonly DRY_RUN RELEASE_NOTES GITHUB_REPOSITORY

readonly SCHEME="Panoptos"
readonly APP_NAME="Panoptos"
readonly NOTARY_PROFILE="panoptos-notary"
readonly SIGN_IDENTITY="Developer ID Application"

# The website continues to host the Sparkle feed. Release assets themselves are
# prepared locally for a separate, explicitly approved GitHub publication.
readonly SITE_DIR="${PANOPTOS_WEBSITE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../panoptos-website" 2>/dev/null && pwd || true)}"
readonly PRODUCT_LINK="https://panoptos.ruverse.ai"

cd "$(dirname "${BASH_SOURCE[0]}")/.."
readonly ROOT="$PWD"
readonly BUILD_DIR="$ROOT/build/release"
readonly ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly APP="$EXPORT_DIR/$APP_NAME.app"
readonly STAGE="$BUILD_DIR/dmg-stage"
readonly MOUNT="$BUILD_DIR/mnt"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# Builds $DMG from $APP: a white folder icon holding the mark as the volume
# icon, the app on the left, an Applications alias on the right, and a
# background arrow between them. A folder written straight into a compressed
# image loses the root's custom-icon flag, so the image is created read-write,
# dressed on its mounted volume, then converted. The custom-icon flag is
# kHasCustomIcon (0x0400) in the finderFlags word at bytes 8-9 of the 32-byte
# FinderInfo. The window layout is written by scripts/dmg-layout.py rather
# than through Finder scripting: Finder no longer persists scripted view
# options, and it strips the volume icon while it works. The trap keeps a
# failure between attach and detach from leaving the image mounted.
build_disk_image() {
    local rw_dmg="$BUILD_DIR/$APP_NAME-rw.dmg"
    local assets="$BUILD_DIR/dmg-assets"
    local volume_name="$APP_NAME $VERSION"
    local glyph="$ROOT/Panoptos/Resources/AppIcon.icon/Assets/AppIconGlyph.svg"
    [[ -f "$glyph" ]] || fail "app icon glyph not found at $glyph"

    local macos_sdk
    macos_sdk=$(xcrun --sdk macosx --show-sdk-path) \
        || fail "could not locate Xcode's macOS SDK"
    xcrun --sdk macosx swift -sdk "$macos_sdk" -target "$(uname -m)-apple-macos14.0" \
        "$ROOT/scripts/dmg-assets.swift" "$glyph" "$assets" \
        || fail "could not generate the disk image assets"
    tiffutil -cathidpicheck "$assets/background.png" "$assets/background@2x.png" \
        -out "$assets/background.tiff" >/dev/null 2>&1 \
        || fail "could not combine the background images"

    rm -rf "$STAGE" "$rw_dmg" "$DMG"
    mkdir -p "$STAGE/.background"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "$assets/VolumeIcon.icns" "$STAGE/.VolumeIcon.icns"
    cp "$assets/background.tiff" "$STAGE/.background/background.tiff"

    hdiutil create \
        -volname "$volume_name" \
        -srcfolder "$STAGE" \
        -fs HFS+ \
        -format UDRW \
        -ov \
        "$rw_dmg" >/dev/null

    # Mounted under /Volumes so the background alias records the path users
    # will see, but not browsable, so Finder cannot rewrite the layout.
    local volume="/Volumes/$volume_name"
    [[ ! -e "$volume" ]] || fail "a volume named '$volume_name' is already mounted; eject it first"
    trap 'hdiutil detach "$volume" >/dev/null 2>&1 || true' EXIT
    hdiutil attach "$rw_dmg" -readwrite -nobrowse -quiet
    [[ -d "$volume" ]] || fail "the read-write image did not mount at $volume"

    # Positions and window size match scripts/dmg-assets.swift, which draws the
    # arrow between these two icon centers.
    python3 "$ROOT/scripts/dmg-layout.py" \
        --volume "$volume" \
        --background ".background/background.tiff" \
        --window 200,200,660,400 \
        --icon-size 128 \
        --text-size 13 \
        --item "$APP_NAME.app=180,190" \
        --item "Applications=480,190" \
        || fail "could not write the disk image window layout"
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" \
        "$volume"

    sync
    hdiutil detach "$volume" >/dev/null
    trap - EXIT

    hdiutil convert "$rw_dmg" -format UDZO -o "$DMG" >/dev/null
    rm -f "$rw_dmg"
}

if [[ -n "$RELEASE_NOTES" && "$RELEASE_NOTES" == "$BUILD_DIR/"* ]]; then
    fail "release notes cannot be inside $BUILD_DIR because that directory is recreated"
fi

# ---------------------------------------------------------------- preflight

step "Preflight"

read -r DEBUG_VERSION DEBUG_BUILD < <(
    xcodebuild -project "$APP_NAME.xcodeproj" -target "$APP_NAME" \
        -configuration Debug -showBuildSettings 2>/dev/null \
        | awk '/ MARKETING_VERSION =/ {v=$3} / CURRENT_PROJECT_VERSION =/ {b=$3} END {print v, b}'
)
read -r VERSION BUILD_NUMBER < <(
    xcodebuild -project "$APP_NAME.xcodeproj" -target "$APP_NAME" \
        -configuration Release -showBuildSettings 2>/dev/null \
        | awk '/ MARKETING_VERSION =/ {v=$3} / CURRENT_PROJECT_VERSION =/ {b=$3} END {print v, b}'
)
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || fail "MARKETING_VERSION must be a stable semantic version without leading zeroes"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "CURRENT_PROJECT_VERSION must be a positive integer"
[[ "$DEBUG_VERSION" == "$VERSION" && "$DEBUG_BUILD" == "$BUILD_NUMBER" ]] \
    || fail "Debug and Release version/build settings must match"

if [[ "$DRY_RUN" == false ]]; then
    published_appcast=$(mktemp "${TMPDIR:-/tmp}/panoptos-appcast.XXXXXX")
    trap 'rm -f "$published_appcast"' EXIT
    curl --fail --silent --show-error --location \
        "${PRODUCT_LINK}/appcast.xml" -o "$published_appcast" \
        || fail "could not read the published Sparkle appcast"
    python3 - "$published_appcast" "$VERSION" "$BUILD_NUMBER" <<'PY' \
        || fail "version/build must be greater than every published appcast item"
import sys
import xml.etree.ElementTree as ET

path, version_text, build_text = sys.argv[1:]
candidate_version = tuple(map(int, version_text.split(".")))
candidate_build = int(build_text)
versions = []
builds = []
for element in ET.parse(path).getroot().iter():
    name = element.tag.rsplit("}", 1)[-1]
    value = (element.text or "").strip()
    if name == "shortVersionString" and value:
        versions.append(tuple(map(int, value.split("."))))
    elif name == "version" and value.isdigit():
        builds.append(int(value))
if versions and candidate_version <= max(versions):
    raise SystemExit(1)
if builds and candidate_build <= max(builds):
    raise SystemExit(1)
PY

    repository_api="https://api.github.com/repos/$GITHUB_REPOSITORY"
    repository_status=$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' "$repository_api") \
        || fail "could not query the canonical GitHub repository"
    if [[ "$repository_status" == "200" ]]; then
        existing_tag=$(git ls-remote "https://github.com/${GITHUB_REPOSITORY}.git" \
            "refs/tags/v$VERSION" 2>/dev/null) \
            || fail "could not inspect existing GitHub tags"
        [[ -z "$existing_tag" ]] || fail "GitHub tag v$VERSION already exists"
        release_status=$(curl --silent --show-error --output /dev/null \
            --write-out '%{http_code}' "$repository_api/releases/tags/v$VERSION") \
            || fail "could not inspect existing GitHub releases"
        [[ "$release_status" == "404" ]] || fail "GitHub release v$VERSION already exists or could not be verified"
    elif [[ "$repository_status" != "404" ]]; then
        fail "unexpected GitHub repository response: HTTP $repository_status"
    fi
    rm -f "$published_appcast"
    trap - EXIT
fi

# Every check below greps a captured string rather than a pipeline. Under
# `set -o pipefail`, `grep -q` exits on its first match, the producing command
# dies on SIGPIPE, and the pipeline reports failure even though the match
# succeeded. For the get-task-allow check that inverts the meaning of the test.
identities=$(security find-identity -v -p codesigning)
grep -q "$SIGN_IDENTITY" <<<"$identities" \
    || fail "no '$SIGN_IDENTITY' certificate in the keychain"

# The team lives in an untracked local file so the project does not name one
# developer's Apple account. It is not a secret, just not everyone's to share.
[[ -f "$ROOT/Signing.local.xcconfig" ]] \
    || fail "Signing.local.xcconfig is missing; copy Signing.local.xcconfig.example and set your team"
TEAM_ID=$(awk -F'=' '/PANOPTOS_DEVELOPMENT_TEAM/ {gsub(/[ \t]/, "", $2); print $2}' \
    "$ROOT/Signing.local.xcconfig")
[[ -n "$TEAM_ID" ]] || fail "PANOPTOS_DEVELOPMENT_TEAM is not set in Signing.local.xcconfig"

if [[ "$DRY_RUN" == false ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notary profile '$NOTARY_PROFILE' is missing or invalid"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        printf 'warning: working tree is dirty; the build will not match a clean checkout\n'
    else
        fail "app working tree is dirty; commit or restore it before staging a release"
    fi
fi

if [[ "$DRY_RUN" == false ]]; then
    [[ "$(git branch --show-current)" == "main" ]] \
        || fail "a release must be staged from main"
    [[ -n "$SITE_DIR" && -d "$SITE_DIR/.git" ]] \
        || fail "website checkout not found; set PANOPTOS_WEBSITE to panoptos-website"
    [[ "$(git -C "$SITE_DIR" branch --show-current)" == "main" ]] \
        || fail "website checkout must be on main"
    [[ -z "$(git -C "$SITE_DIR" status --porcelain)" ]] \
        || fail "website working tree is dirty; publish or restore it before staging a release"

    command -v xmllint >/dev/null 2>&1 \
        || fail "xmllint is required to validate the generated appcast"
    generate_appcast=$(
        find "$HOME/Library/Developer/Xcode/DerivedData" \
            -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' \
            -type f 2>/dev/null
    )
    generate_appcast=${generate_appcast%%$'\n'*}
    [[ -x "$generate_appcast" ]] \
        || fail "generate_appcast not found; resolve the Sparkle package and re-run"
    generate_keys="$(dirname "$generate_appcast")/generate_keys"
    [[ -x "$generate_keys" ]] \
        || fail "generate_keys not found beside generate_appcast"

    expected_public_key=$(plutil -extract SUPublicEDKey raw "$ROOT/Panoptos/Info.plist" 2>/dev/null) \
        || fail "could not read SUPublicEDKey from Info.plist"
    available_public_key=$("$generate_keys" -p) \
        || fail "Sparkle's ed25519 private key is missing or unavailable in the login keychain"
    [[ "$available_public_key" == "$expected_public_key" ]] \
        || fail "Sparkle's keychain key does not match SUPublicEDKey in Info.plist"
fi

if [[ "$DRY_RUN" == false && -e "$SITE_DIR/public/downloads/$BUILD_NUMBER" ]]; then
    fail "build $BUILD_NUMBER already has a published download directory; bump CURRENT_PROJECT_VERSION"
fi

readonly DMG="$BUILD_DIR/$APP_NAME.dmg"
printf 'Panoptos %s (%s)\n' "$VERSION" "$BUILD_NUMBER"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ------------------------------------------------------------------ archive

step "Archiving"

# generic/platform=macOS keeps both architectures; a concrete destination
# would silently produce a thin binary for this Mac only.
xcodebuild archive \
    -allowProvisioningUpdates \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    | grep -E "ARCHIVE (SUCCEEDED|FAILED)|error:" || true

[[ -d "$ARCHIVE" ]] || fail "archive was not produced"

step "Exporting"

# Generated rather than tracked, so the team ID stays in the one untracked file
# that already holds it.
export_options="$BUILD_DIR/ExportOptions.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>destination</key>
    <string>export</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$export_options" \
    | grep -E "EXPORT (SUCCEEDED|FAILED)|error:" || true

[[ -d "$APP" ]] || fail "export did not produce $APP_NAME.app"

# -------------------------------------------------------- signature audit

step "Auditing the signature"

# Each of these is a notarization prerequisite that fails late and cryptically
# if it is wrong, so check them before spending a round trip on the upload.
codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | tail -2

signature=$(codesign -dvvvv "$APP" 2>&1)
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)

grep -q "flags=.*runtime" <<<"$signature" \
    || fail "hardened runtime is not enabled"
grep -qi "^Timestamp=" <<<"$signature" \
    || fail "signature has no secure timestamp"
grep -q "TeamIdentifier=$TEAM_ID" <<<"$signature" \
    || fail "unexpected team identifier"
grep -q "Authority=Developer ID Application" <<<"$signature" \
    || fail "not signed with a Developer ID Application certificate"
if grep -q "get-task-allow" <<<"$entitlements"; then
    fail "com.apple.security.get-task-allow is present; notarization will reject this"
fi
if grep -q "<key>keychain-access-groups</key>" <<<"$entitlements"; then
    fail "the removed licensing Keychain entitlement is still present"
fi

# The notary service checks every nested code item, not just the outer bundle.
# Sparkle contributes a framework, an Updater app, an Autoupdate helper, and two
# XPC services; any one of them missing the runtime flag or a timestamp fails
# the whole submission, so audit them individually.
nested_failures=0
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    nested_signature=$(codesign -dvvvv "$item" 2>&1)
    if ! grep -q "flags=.*runtime" <<<"$nested_signature"; then
        printf 'nested item lacks hardened runtime: %s\n' "${item#"$APP/"}" >&2
        nested_failures=$((nested_failures + 1))
    fi
    if ! grep -qi "^Timestamp=" <<<"$nested_signature"; then
        printf 'nested item lacks a secure timestamp: %s\n' "${item#"$APP/"}" >&2
        nested_failures=$((nested_failures + 1))
    fi
done < <(
    find "$APP/Contents/Frameworks" -maxdepth 1 -mindepth 1 2>/dev/null
    find "$APP/Contents/Frameworks" \
        \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) 2>/dev/null
)
(( nested_failures == 0 )) || fail "$nested_failures nested signing problem(s); notarization would reject this"

nested_count=$(find "$APP/Contents/Frameworks" \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) 2>/dev/null | wc -l | tr -d ' ')

ARCHS_FOUND=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
printf 'architectures: %s\n' "$ARCHS_FOUND"
printf 'nested code:   %s item(s), all hardened and timestamped\n' "$nested_count"
printf 'signature:     ok (hardened runtime, timestamped, no licensing or debug entitlement)\n'

if [[ "$DRY_RUN" == true ]]; then
    step "Building the disk image"
    build_disk_image

    step "Dry run complete"
    printf 'Built and verified %s\nBuilt %s for local inspection; it is not signed, notarized, or stapled.\n' \
        "$APP" "$DMG"
    exit 0
fi

# ------------------------------------------------------- notarize the app

step "Notarizing the app"

readonly APP_ZIP="$BUILD_DIR/$APP_NAME-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"

xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    || fail "app notarization failed; run 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE' for detail"

xcrun stapler staple "$APP" || fail "could not staple the app"
rm -f "$APP_ZIP"

# ------------------------------------------------------- build the image

step "Building the disk image"

build_disk_image
codesign --sign "$SIGN_IDENTITY" --timestamp --force "$DMG"

step "Notarizing the disk image"

xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    || fail "disk image notarization failed"

xcrun stapler staple "$DMG" || fail "could not staple the disk image"

# ------------------------------------------------------------ final check

step "Verifying the result"

# Assess the image as Gatekeeper will, then assess the app as a copy taken out
# of the image, which is how it will actually be installed.
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | tail -3
xcrun stapler validate "$DMG" 2>&1 | tail -1

readonly CHECK_DIR="$BUILD_DIR/verify"
mkdir -p "$CHECK_DIR" "$MOUNT"

# An explicit -mountpoint avoids scraping stdout for the mount path. hdiutil
# interleaves checksum progress with the mount table there, so matching by
# pattern finds the progress line instead. The trap keeps a failure between
# attach and detach from leaving the image mounted.
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
cp -R "$MOUNT/$APP_NAME.app" "$CHECK_DIR/"
hdiutil detach "$MOUNT" >/dev/null
trap - EXIT

spctl --assess --type execute -vv "$CHECK_DIR/$APP_NAME.app" 2>&1 | tail -3
xcrun stapler validate "$CHECK_DIR/$APP_NAME.app" 2>&1 | tail -1
rm -rf "$CHECK_DIR"

# ---------------------------------------- prepare release assets and appcast

# The appcast is generated, never hand-edited. Every entry carries an EdDSA
# signature over the exact bytes of its disk image, so editing the file by hand
# invalidates it. generate_appcast recomputes the signature, the length, and the
# minimum OS version from the image itself.
step "Preparing release assets and appcast"

# The version tag and release assets are created only after explicit approval.
# The feed points at their future immutable GitHub URLs, and must not be
# published until those assets are anonymously reachable.
release_tag="v$VERSION"
downloads="$BUILD_DIR/candidate/$release_tag"
download_url_prefix="https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/"
staged_dmg="$downloads/$(basename "$DMG")"
staged_notes="$downloads/$APP_NAME.md"
mkdir -p "$downloads"
cp "$DMG" "$staged_dmg"
cp "$RELEASE_NOTES" "$staged_notes"
cat >> "$staged_notes" <<NOTICES

---

Panoptos is free software under GPL-3.0-or-later. Matching source for this
build: ${download_url_prefix}Panoptos-${VERSION}-source.tar.gz
NOTICES
source_archive=$("$ROOT/scripts/package-source.sh" \
    --version "$VERSION" \
    --build "$BUILD_NUMBER" \
    --commit HEAD \
    --output "$downloads")

# Seed generation with the current feed so historical entries and download
# paths remain intact while Sparkle adds the new immutable GitHub enclosure.
cp "$SITE_DIR/public/appcast.xml" "$downloads/appcast.xml"

"$generate_appcast" \
    --download-url-prefix "$download_url_prefix" \
    --embed-release-notes \
    --link "$PRODUCT_LINK" \
    -o "$downloads/appcast.xml" \
    "$downloads"

# The generator must retain every earlier item and enclosure. Compare the
# candidate against the unchanged live-feed checkout before staging it.
python3 - "$SITE_DIR/public/appcast.xml" "$downloads/appcast.xml" <<'PY' \
    || fail "generated appcast did not preserve all historical entries"
import sys
import xml.etree.ElementTree as ET

def identities(path):
    result = set()
    for item in ET.parse(path).getroot().iter():
        if item.tag.rsplit("}", 1)[-1] != "item":
            continue
        version = ""
        enclosure = ""
        for child in item:
            name = child.tag.rsplit("}", 1)[-1]
            if name == "version":
                version = (child.text or "").strip()
            elif name == "enclosure":
                enclosure = child.attrib.get("url", "")
        if version or enclosure:
            result.add((version, enclosure))
    return result

old = identities(sys.argv[1])
new = identities(sys.argv[2])
missing = old - new
if missing:
    for version, enclosure in sorted(missing):
        print(f"missing historical item {version}: {enclosure}", file=sys.stderr)
    raise SystemExit(1)
PY

# Select the complete item for this build so validation cannot accidentally
# pass because an older item elsewhere in the feed has the expected field.
item_xpath="/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][*[local-name()='version' and normalize-space(text())='$BUILD_NUMBER']]"
item_count=$(xmllint --xpath "count($item_xpath)" "$downloads/appcast.xml" 2>/dev/null) \
    || fail "could not parse the generated appcast"
[[ "$item_count" == "1" ]] \
    || fail "generated appcast has $item_count items for build $BUILD_NUMBER; expected one"
current_item=$(xmllint --xpath "$item_xpath" "$downloads/appcast.xml" 2>/dev/null) \
    || fail "could not read the appcast item for build $BUILD_NUMBER"
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" \
    <<<"$current_item" \
    || fail "appcast item for build $BUILD_NUMBER is not version $VERSION"
grep -q 'sparkle:edSignature=' <<<"$current_item" \
    || fail "appcast item for build $BUILD_NUMBER has no EdDSA signature"
description=$(
    xmllint --xpath \
        "normalize-space(string($item_xpath/*[local-name()='description']))" \
        "$downloads/appcast.xml" 2>/dev/null
) || fail "could not read embedded release notes from the generated appcast"
[[ -n "$description" ]] \
    || fail "appcast item for build $BUILD_NUMBER has empty release notes"

# The signature and length cover the exact bytes of the staged image. If the
# copy is truncated or from another build, every client silently rejects it.
staged_bytes=$(stat -f "%z" "$staged_dmg")
current_enclosure=$(grep \
    "url=\"${download_url_prefix}$(basename "$DMG")\"" \
    <<<"$current_item") \
    || fail "generated appcast has no enclosure for build $BUILD_NUMBER"
appcast_bytes=$(grep -o 'length="[0-9]*"' <<<"$current_enclosure" \
    | tr -dc '0-9')
[[ "$staged_bytes" == "$appcast_bytes" ]] \
    || fail "appcast length ($appcast_bytes) does not match the staged image ($staged_bytes)"
cmp -s "$DMG" "$staged_dmg" \
    || fail "staged image differs from the notarized one"
grep -Fq "${download_url_prefix}Panoptos-${VERSION}-source.tar.gz" "$staged_notes" \
    || fail "staged release notes do not link the matching source archive"

prepared_commit=$(git rev-parse HEAD)
python3 - "$downloads/candidate.json" "$VERSION" "$BUILD_NUMBER" \
    "$prepared_commit" "$GITHUB_REPOSITORY" "$release_tag" <<'PY'
import json
import sys

path, version, build, commit, repository, tag = sys.argv[1:]
metadata = {
    "version": version,
    "build": int(build),
    "commit": commit,
    "repository": repository,
    "tag": tag,
    "binary": "Panoptos.dmg",
    "source": f"Panoptos-{version}-source.tar.gz",
    "appcast": "appcast.xml",
    "signing": "Developer ID, hardened runtime, secure timestamps",
    "notarization": "app and disk image accepted and stapled",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, indent=2)
    handle.write("\n")
PY
(
    cd "$downloads"
    shasum -a 256 "$(basename "$staged_dmg")" "$(basename "$source_archive")" \
        "$APP_NAME.md" appcast.xml candidate.json > SHA256SUMS
)

# Stage the website feed only after all content, history, signature, length,
# source-link, and checksum validation has passed.
cp "$downloads/appcast.xml" "$SITE_DIR/public/appcast.xml"

printf 'appcast:   %s\n' "$SITE_DIR/public/appcast.xml"
printf 'download:  %s (%s bytes, matches appcast)\n' "$staged_dmg" "$staged_bytes"
printf 'notes:     %s (embedded and non-empty)\n' "$staged_notes"
printf 'source:    %s\n' "$source_archive"
printf 'metadata:  %s\n' "$downloads/candidate.json"
printf 'checksums: %s\n' "$downloads/SHA256SUMS"

step "Done"
printf 'Signed, notarized, and stapled:\n  %s (%s bytes)\n\n' \
    "$DMG" "$(stat -f "%z" "$DMG")"
printf 'To publish:\n'
printf '  1. Show the exact commit, notes, hashes, and signing evidence; wait for explicit approval.\n'
printf '  2. Create immutable tag %s at the prepared commit and publish the files in:\n' "$release_tag"
printf '       %s\n' "$downloads"
printf '  3. Only after GitHub assets are reachable, publish the staged website appcast:\n'
printf '       cd %s && git add public/appcast.xml && git commit && git push\n' "${SITE_DIR:-../panoptos-website}"
printf '  4. confirm the feed and immutable GitHub image both resolve with HTTP 200:\n'
printf '       curl -sSI %sappcast.xml | head -1\n' "${PRODUCT_LINK}/"
printf '       curl -sSI %s%s | head -1\n' "$download_url_prefix" "$(basename "$DMG")"
printf '\n'
printf 'Never publish the appcast before the immutable GitHub assets are available.\n'
