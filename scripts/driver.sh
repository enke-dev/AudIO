#!/usr/bin/env bash
# Builds and installs the AudIO virtual audio driver (HAL plug-in).
#   scripts/driver.sh [build|install|uninstall|log]
# Env: CODESIGN_IDENTITY (default "-" = ad-hoc, fine for local use)
set -euo pipefail

cd "$(dirname "$0")/.."
command="${1:-build}"
identity="${CODESIGN_IDENTITY:--}"
bundle="build/AudIO.driver"
target="/Library/Audio/Plug-Ins/HAL/AudIO.driver"

build() {
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS"
    clang -bundle \
        -arch arm64 \
        -mmacosx-version-min=14.2 \
        -O2 -Wall -Wextra -Werror=incompatible-pointer-types \
        -fvisibility=hidden \
        -framework CoreFoundation -framework CoreAudio \
        -o "$bundle/Contents/MacOS/AudIO" \
        Driver/AudIO.c
    cp Driver/Info.plist "$bundle/Contents/Info.plist"
    # Device icon for the Sound menu, compiled from Resources/Icon.icon.
    if scripts/app.sh icon; then
        mkdir -p "$bundle/Contents/Resources"
        cp build/icon/Icon.icns "$bundle/Contents/Resources/Icon.icns"
    fi
    codesign --force --sign "$identity" --timestamp=none "$bundle"
    echo "Built $bundle"
}

restart_coreaudio() {
    # launchd restarts it right away; all audio drops out for a moment. A plain SIGTERM lets
    # coreaudiod shut down cleanly – repeated -9 kills left the audio system wedged.
    sudo killall coreaudiod 2>/dev/null || true
}

case "$command" in
    build) build ;;
    install)
        build
        sudo rm -rf "$target"
        sudo cp -R "$bundle" "$target"
        sudo chown -R root:wheel "$target"
        restart_coreaudio
        echo "Installed $target"
        ;;
    uninstall)
        sudo rm -rf "$target"
        restart_coreaudio
        echo "Removed $target"
        ;;
    log)
        # Driver messages plus coreaudiod complaints about the plug-in.
        log stream --level debug --predicate \
            'subsystem == "dev.enke.AudIO.Driver" OR (process == "coreaudiod" AND eventMessage CONTAINS[c] "AudIO")'
        ;;
    *) echo "usage: $0 [build|install|uninstall|log]" >&2; exit 1 ;;
esac
