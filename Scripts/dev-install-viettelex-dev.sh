#!/bin/zsh
# Build and test the isolated VietTelex Dev input source, then install only that bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

readonly STABLE_BUNDLE_ID="com.viettelex.inputmethod.telex"
readonly DEV_BUNDLE_ID="com.viettelex.inputmethod.viettelexdev"
readonly DEV_SOURCE_ID="${DEV_BUNDLE_ID}.vi"
readonly DEV_CONNECTION="${DEV_BUNDLE_ID}_Connection"
readonly DEST="$HOME/Library/Input Methods/VietTelex Dev.app"
readonly STABLE_DEST="$HOME/Library/Input Methods/VietTelex.app"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly DERIVED="${TMPDIR:-/tmp}/viettelex-derived-viettelex-dev"
readonly BUILD_APP="$DERIVED/Build/Products/Debug/VietTelex.app"

OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if (( OS_MAJOR >= 26 )); then
    print -u2 "VietTelex Dev installs an ad-hoc build; macOS ${OS_VERSION} requires notarization."
    print -u2 "Refusing to register this input-method identity because macOS can cache a failed registration."
    exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    SELECTED_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
    if [[ "$SELECTED_DEVELOPER_DIR" == *CommandLineTools* \
          && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    print -u2 "xcodegen is required. Install it with: brew install xcodegen"
    exit 1
fi

read_bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

verify_dev_bundle() {
    local app="$1"
    local info="$app/Contents/Info.plist"
    local bundle_id source_id connection executable
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
    source_id="$(/usr/libexec/PlistBuddy -c "Print :ComponentInputModeDict:tsInputModeListKey:${DEV_SOURCE_ID}:TISInputSourceID" "$info")"
    connection="$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' "$info")"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
    [[ "$bundle_id" == "$DEV_BUNDLE_ID" ]]
    [[ "$source_id" == "$DEV_SOURCE_ID" ]]
    [[ "$connection" == "$DEV_CONNECTION" ]]
    [[ "$executable" == "VietTelexDev" ]]
    /usr/bin/codesign --verify --deep --strict "$app"
}

STAGE_DIR=""
OLD_APP=""
INSTALL_SWAP_STARTED=0
INSTALL_COMMITTED=0
BUILD_APP_UNREGISTERED=0
cleanup() {
    local exit_status=$?
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        if (( INSTALL_SWAP_STARTED && ! INSTALL_COMMITTED )); then
            if [[ -n "$OLD_APP" && -e "$OLD_APP" ]]; then
                if [[ -e "$DEST" ]]; then /bin/rm -rf "$DEST"; fi
                /bin/mv "$OLD_APP" "$DEST"
            elif [[ -e "$DEST" ]]; then
                /bin/rm -rf "$DEST"
            fi
        fi
        /bin/rm -rf "$STAGE_DIR"
    fi
    if (( exit_status != 0 && BUILD_APP_UNREGISTERED )) && [[ -d "$DEST" ]] \
       && [[ "$(read_bundle_id "$DEST")" == "$DEV_BUNDLE_ID" ]]; then
        "$LSREGISTER" -f "$DEST" >/dev/null
        DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}" \
            /usr/bin/swift "$ROOT/Scripts/enable-dev-input-source.swift" "$DEST" "$DEV_BUNDLE_ID" "$DEV_SOURCE_ID" >/dev/null
    fi
    return "$exit_status"
}
trap cleanup EXIT

xcodegen generate
/usr/bin/xcodebuild \
    -project "$ROOT/VietTelex.xcodeproj" \
    -scheme VietTelex \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    test

verify_dev_bundle "$BUILD_APP"

if [[ -e "$STABLE_DEST" ]]; then
    INSTALLED_STABLE_ID="$(read_bundle_id "$STABLE_DEST")"
    if [[ "$INSTALLED_STABLE_ID" != "$STABLE_BUNDLE_ID" ]]; then
        print -u2 "Stable app path has unexpected bundle ID: $INSTALLED_STABLE_ID"
        exit 1
    fi
fi

if [[ -e "$DEST" ]]; then
    INSTALLED_DEV_ID="$(read_bundle_id "$DEST")"
    if [[ "$INSTALLED_DEV_ID" != "$DEV_BUNDLE_ID" ]]; then
        print -u2 "Refusing to replace an app that is not VietTelex Dev: $DEST"
        exit 1
    fi
fi

# The test product shares the Dev bundle ID. Unregister it before registering the
# installed copy, otherwise Launch Services may resolve the wrong path.
"$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
BUILD_APP_UNREGISTERED=1

INPUT_METHODS_DIR="$HOME/Library/Input Methods"
/bin/mkdir -p "$INPUT_METHODS_DIR"
STAGE_DIR="$(/usr/bin/mktemp -d "$INPUT_METHODS_DIR/.VietTelexDev.install.XXXXXX")"
STAGED_APP="$STAGE_DIR/VietTelex Dev.app"
OLD_APP="$STAGE_DIR/previous.app"
/usr/bin/ditto "$BUILD_APP" "$STAGED_APP"
verify_dev_bundle "$STAGED_APP"

# This executable name is unique to Dev, so the stable IME keeps running.
/usr/bin/pkill -x VietTelexDev 2>/dev/null || true
for _ in {1..30}; do
    /usr/bin/pgrep -x VietTelexDev >/dev/null 2>&1 || break
    /bin/sleep 0.1
done
if /usr/bin/pgrep -x VietTelexDev >/dev/null 2>&1; then
    print -u2 "VietTelex Dev is still running; refusing to replace its bundle."
    exit 1
fi

if [[ -e "$DEST" ]]; then
    /bin/mv "$DEST" "$OLD_APP"
fi
INSTALL_SWAP_STARTED=1
if ! /bin/mv "$STAGED_APP" "$DEST"; then
    print -u2 "Could not move VietTelex Dev into $INPUT_METHODS_DIR"
    exit 1
fi

"$LSREGISTER" -f "$DEST"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}" \
    /usr/bin/swift "$ROOT/Scripts/enable-dev-input-source.swift" "$DEST" "$DEV_BUNDLE_ID" "$DEV_SOURCE_ID"
INSTALL_COMMITTED=1
print "Installed, tested, and registered VietTelex Dev at: $DEST"
print "If it is not in the input menu, add it in System Settings → Keyboard → Text Input → Input Sources."
print "Accessibility access is separate; the ad-hoc Dev build will not request it automatically."
print "macOS may require logging out and back in after first registration or input-mode metadata changes."
