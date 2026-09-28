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

# The widget extension, built like Xcode would: compiled with the App Intents' constant
# values, linked with the extension entry point (`@main` alone crashed while bootstrapping),
# plus the App Intents metadata – without it, its button's action isn't found.
build_widget() {
    local widget="$1" out=build/widget
    rm -rf "$out" && mkdir -p "$out/meta" "$widget/Contents/MacOS" "$widget/Contents/Resources"
    local target=arm64-apple-macos14.2
    swiftc -O -wmo -c -target "$target" -parse-as-library -application-extension -module-name AudIOWidget \
        -emit-const-values-path "$out/AudIOWidget.swiftconstvalues" \
        -Xfrontend -const-gather-protocols-file -Xfrontend Widget/const-protocols.json \
        Widget/*.swift -o "$out/AudIOWidget.o"
    swiftc -target "$target" -application-extension -Xlinker -e -Xlinker _NSExtensionMain \
        "$out/AudIOWidget.o" -o "$out/AudIOWidget"
    for source in Widget/*.swift; do realpath "$source"; done > "$out/sources.txt"
    realpath "$out/AudIOWidget.swiftconstvalues" > "$out/constvalues.txt"
    xcrun appintentsmetadataprocessor --output "$out/meta" \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
        --module-name AudIOWidget --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS --deployment-target 14.2 --target-triple "$target" \
        --source-file-list "$out/sources.txt" --swift-const-vals-list "$out/constvalues.txt" \
        --binary-file "$out/AudIOWidget" >/dev/null 2>&1
    cp "$out/AudIOWidget" "$widget/Contents/MacOS/"
    cp -R "$out/meta/Metadata.appintents" "$widget/Contents/Resources/"
    xcrun xcstringstool compile Widget/Localizable.xcstrings --output-directory "$widget/Contents/Resources" >/dev/null
    cp Widget/Info.plist "$widget/Contents/Info.plist"
    codesign --force --sign "$identity" --timestamp=none --entitlements Widget/Widget.entitlements "$widget"
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

    # Desktop widget (WidgetKit extension, sandboxed), signed before the app around it.
    build_widget "$app/Contents/PlugIns/AudIOWidget.appex"

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
    # A running widget process keeps its old code, and the widget hosts their rendered
    # snapshots – restarted, desktop widgets redraw with the new build (they flicker once).
    pkill -x AudIOWidget 2>/dev/null || true
    killall chronod NotificationCenter 2>/dev/null || true
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
