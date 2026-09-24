#!/usr/bin/env bash
# Builds AudIO.app from the Swift package.
#   scripts/app.sh [build|run|install|icon]
# Env: CONFIGURATION (release|debug, default release)
#      CODESIGN_IDENTITY (default: "AudIO Code Signing" from the keychain if present –
#      see scripts/signing.sh – else "-" = ad-hoc. A stable identity keeps the audio
#      capture and microphone permissions across rebuilds.)
set -euo pipefail

cd "$(dirname "$0")/.."
command="${1:-build}"
configuration="${CONFIGURATION:-release}"
identity="${CODESIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="-"
    if security find-certificate -c "AudIO Code Signing" >/dev/null 2>&1; then identity="AudIO Code Signing"; fi
fi
app="build/AudIO.app"

# Compiles the Icon Composer file into Assets.car (+ Icon.icns for macOS < 26).
# Needs Xcode 26+; without it the app is built with the generic icon.
icon_dir="build/icon"

compile_icon() {
    local out="$icon_dir"
    rm -rf "$out" && mkdir -p "$out"
    if xcrun actool Resources/Icon.icon \
        --compile "$out" \
        --app-icon Icon \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.2 \
        --enable-on-demand-resources NO \
        --development-region en \
        --output-partial-info-plist "$out/partial.plist" >/dev/null; then
        return 0
    else
        echo "warning: could not compile Resources/Icon.icon (Xcode 26+ required), using the default icon" >&2
        return 1
    fi
}

build() {
    # Apple Silicon only.
    swift build -c "$configuration" --arch arm64
    local bin
    bin="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin/AudIO" "$app/Contents/MacOS/AudIO"
    cp Resources/Info.plist "$app/Contents/Info.plist"
    # Translations: the String Catalogs compile into <lang>.lproj/*.strings(dict).
    for catalog in Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings; do
        xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources" >/dev/null
    done

    # Bundled driver, installed from the app ("Install audio device"). Its build also
    # compiles the icon into $icon_dir.
    CODESIGN_IDENTITY="$identity" scripts/driver.sh build
    cp -R build/AudIO.driver "$app/Contents/Resources/"
    cp "$icon_dir"/Assets.car "$icon_dir"/Icon.icns "$app/Contents/Resources/" 2>/dev/null || true

    codesign --force --sign "$identity" --timestamp=none "$app"
    # The bundle is recreated at the same path – make Finder/LaunchServices drop the cached icon.
    touch "$app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" || true
    echo "Built $app (signed with: $identity)"
}

# Quits AudIO properly (it restores the sound output) and waits until it's gone – opening
# the app while the old process is still exiting fails with LaunchServices error -600.
quit() {
    pgrep -x AudIO >/dev/null || return 0 # (AppleScript would launch it just to quit it)
    osascript -e 'quit app id "dev.enke.AudIO"' 2>/dev/null || true
    for _ in $(seq 50); do pgrep -x AudIO >/dev/null || return 0; sleep 0.1; done
    pkill -x AudIO 2>/dev/null || true
    sleep 0.5
}

relaunch() {
    quit
    open "$1"
}

case "$command" in
    build) build ;;
    icon) compile_icon ;;
    run) build && relaunch "$app" ;;
    install)
        build
        quit
        rm -rf /Applications/AudIO.app
        cp -R "$app" /Applications/
        relaunch /Applications/AudIO.app
        ;;
    *) echo "usage: $0 [build|run|install|icon]" >&2; exit 1 ;;
esac
