#!/bin/bash
# Build the corresponding-source archive shipped beside an official Panoptos
# binary. It contains the exact tracked app tree and the pinned Sparkle source.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  scripts/package-source.sh --version X.Y.Z --build N --output DIRECTORY [options]

Options:
  --version X.Y.Z       Stable marketing version represented by the archive.
  --build N             Positive integer build number represented by the archive.
  --output DIRECTORY    Directory that receives Panoptos-X.Y.Z-source.tar.gz.
  --commit SHA          Commit to archive (default: HEAD; must resolve to HEAD).
  --derived-data PATH   Xcode DerivedData containing the resolved Sparkle checkout.
  -h, --help            Show this help.

SPARKLE_SOURCE_DIR may name an already resolved Sparkle checkout. Otherwise the
script looks under --derived-data and Xcode's standard DerivedData directory.
USAGE
}

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

VERSION=""
BUILD_NUMBER=""
OUTPUT_DIR=""
COMMIT="HEAD"
DERIVED_DATA=""

while (( $# > 0 )); do
    case "$1" in
        --version|--build|--output|--commit|--derived-data)
            (( $# >= 2 )) || fail "$1 requires a value"
            case "$1" in
                --version) VERSION="$2" ;;
                --build) BUILD_NUMBER="$2" ;;
                --output) OUTPUT_DIR="$2" ;;
                --commit) COMMIT="$2" ;;
                --derived-data) DERIVED_DATA="$2" ;;
            esac
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || fail "--version must be a stable semantic version without leading zeroes"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "--build must be a positive integer"
[[ -n "$OUTPUT_DIR" ]] || fail "--output is required"

cd "$(dirname "${BASH_SOURCE[0]}")/.."
readonly ROOT="$PWD"
resolved_commit=$(git rev-parse --verify "${COMMIT}^{commit}") || fail "could not resolve commit: $COMMIT"
head_commit=$(git rev-parse --verify HEAD)
[[ "$resolved_commit" == "$head_commit" ]] \
    || fail "source packaging must use checked-out commit $head_commit, not $resolved_commit"
[[ -z "$(git status --porcelain)" ]] \
    || fail "source packaging requires a clean tracked and untracked working tree"
[[ -z "$(git ls-files --stage | awk '$1 == 160000 {print $4}')" ]] \
    || fail "the application tree contains gitlinks; vendor their source before packaging"

resolved_file="$ROOT/Panoptos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f "$resolved_file" ]] || fail "Package.resolved is missing"
read -r sparkle_revision sparkle_location < <(python3 - "$resolved_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    pins = json.load(handle).get("pins", [])
matches = [pin for pin in pins if pin.get("identity") == "sparkle"]
if len(matches) != 1:
    raise SystemExit("Package.resolved must contain exactly one Sparkle pin")
print(matches[0]["state"]["revision"], matches[0]["location"])
PY
) || fail "could not read the Sparkle pin"
[[ "$sparkle_revision" =~ ^[0-9a-f]{40}$ ]] || fail "Sparkle does not have an immutable revision pin"
[[ "$sparkle_location" == "https://github.com/sparkle-project/Sparkle" ]] \
    || fail "unexpected Sparkle source location: $sparkle_location"

cleanup_dir=$(mktemp -d "${TMPDIR:-/tmp}/panoptos-source.XXXXXX")
trap 'rm -rf "$cleanup_dir"' EXIT

sparkle_source="${SPARKLE_SOURCE_DIR:-}"
if [[ -z "$sparkle_source" && -n "$DERIVED_DATA" ]]; then
    sparkle_source="$DERIVED_DATA/SourcePackages/checkouts/Sparkle"
fi
if [[ -z "$sparkle_source" ]]; then
    sparkle_source=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path '*/SourcePackages/checkouts/Sparkle/.git' -print -quit 2>/dev/null)
    sparkle_source=${sparkle_source%/.git}
fi
if [[ -z "$sparkle_source" || ! -d "$sparkle_source/.git" ]]; then
    sparkle_source="$cleanup_dir/Sparkle"
    git clone --quiet --no-checkout "$sparkle_location" "$sparkle_source" \
        || fail "could not clone the pinned Sparkle source"
fi
git -C "$sparkle_source" cat-file -e "${sparkle_revision}^{commit}" 2>/dev/null \
    || fail "Sparkle checkout does not contain pinned revision $sparkle_revision"
[[ -z "$(git -C "$sparkle_source" ls-tree -r "$sparkle_revision" | awk '$1 == 160000 {print $4}')" ]] \
    || fail "the pinned Sparkle source contains unsupported gitlinks"

mkdir -p "$OUTPUT_DIR"
output_dir=$(cd "$OUTPUT_DIR" && pwd -P)
archive="$output_dir/Panoptos-$VERSION-source.tar.gz"
work_dir="$cleanup_dir/archive"
archive_root="Panoptos-$VERSION-source"
mkdir -p "$work_dir/$archive_root/ThirdParty/Sparkle"

git archive "$resolved_commit" | tar -xf - -C "$work_dir/$archive_root"
git -C "$sparkle_source" archive "$sparkle_revision" \
    | tar -xf - -C "$work_dir/$archive_root/ThirdParty/Sparkle"

cat > "$work_dir/$archive_root/SOURCE-MANIFEST.txt" <<MANIFEST
Panoptos version: $VERSION
Panoptos build: $BUILD_NUMBER
Panoptos commit: $resolved_commit
Sparkle revision: $sparkle_revision
Sparkle source path in this archive: ThirdParty/Sparkle
MANIFEST

cat > "$work_dir/$archive_root/SOURCE-BUILD.md" <<'BUILD'
# Building the supplied source

Panoptos requires macOS 14 or later and Xcode 26 or later. From this directory,
build and test the app without an Apple account or signing identity:

```sh
xcodebuild -project Panoptos.xcodeproj -scheme Panoptos -configuration Debug \
  -derivedDataPath /tmp/PanoptosDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Panoptos.xcodeproj -scheme Panoptos \
  -configuration Debug -derivedDataPath /tmp/PanoptosDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

The checked-in `Package.resolved` pins Sparkle exactly. Swift Package Manager
normally downloads Sparkle's release XCFramework for the Panoptos build. The
complete corresponding Sparkle source is included at `ThirdParty/Sparkle`.
To rebuild that dependency itself from the included source, use its Xcode
project and release scripts:

```sh
cd ThirdParty/Sparkle
xcodebuild -project Sparkle.xcodeproj -scheme Sparkle -configuration Release \
  -derivedDataPath /tmp/SparkleDerivedData build
```

`ThirdParty/Sparkle/Configurations/make-xcframework.sh` and
`make-release-package.sh` are the upstream scripts used to assemble its
XCFramework and Swift package release. They are included with all supporting
project files and source. Production Panoptos signing and notarization are
separate distribution steps and are not required to compile or test the source.
BUILD

COPYFILE_DISABLE=1 tar -czf "$archive" -C "$work_dir" "$archive_root"
tar -tzf "$archive" >/dev/null || fail "source archive verification failed"
printf '%s\n' "$archive"
