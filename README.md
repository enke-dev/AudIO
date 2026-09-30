<p align="center"><img src="https://raw.githubusercontent.com/enke-dev/AudIO/main/docs/icon.png" width="128" alt="AudIO icon"></p>

# AudIO

Play your Mac's audio on several outputs at once (e.g. MacBook speakers + a Bluetooth speaker), each with its own delay and level, kept in sync.

AudIO adds an **AudIO** device to the Sound menu. Select it to start routing, pick another device to stop. The volume keys control the master.

Requires macOS 14.2 or later on Apple Silicon. Available in English, German, French, Italian, Spanish, Portuguese (Brazil), Dutch, Danish, Swedish, Norwegian, Finnish, Polish, Czech, Ukrainian, Japanese, Chinese (Simplified) and Korean.

<p align="center"><img src="https://raw.githubusercontent.com/enke-dev/AudIO/main/docs/screenshot.png" width="381" alt="The AudIO panel in the menu bar: master volume, outputs with level and delay, Measure Delays"></p>

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/enke-dev/AudIO/releases) and drag AudIO to Applications.
2. The app isn't notarized, so macOS blocks it on first launch. Open **System Settings › Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/AudIO.app`.
3. Click **Install Audio Device** in the menu bar panel (asks for your password), then allow system audio recording when prompted.

## Use

- Click the outputs to play on. Each selected output gets a **Level** and a **Delay** slider.
- **Measure Delays** plays short test tones through each output and uses the microphone to align them. Keep the room quiet and the Mac near your listening position.
- **Check for Updates** looks for a new release on GitHub at launch and once a day. **Update to …** next to the title installs it and restarts AudIO.

## Widgets

<p align="center"><img src="https://raw.githubusercontent.com/enke-dev/AudIO/main/docs/widgets.png" width="720" alt="AudIO's desktop widgets: small with mute and volume, medium and large with the outputs, level and delay"></p>

Right-click the desktop › **Edit Widgets** and search for AudIO.

- **AudIO** (small): click it to mute or unmute; the bar shows the volume.
- **AudIO Outputs** (medium, large): the same, plus the outputs – click one to play on it or not. Selected outputs show their level and delay; a long list fades out at the bottom.

Note: the widgets follow changes within a moment, except while AudIO's panel is open – macOS holds widget updates back while their app is in front, and they catch up when it closes. Like all third-party widgets, they sit on the system's dark widget background.

## Build

Requires Xcode 26 or later; build with Xcode 27 for the macOS 27 menu bar behavior (icon highlight, auto-hidden menu bar stays revealed).

```sh
scripts/app.sh run         # build and launch build/AudIO.app (driver bundled)
scripts/driver.sh install  # install the driver directly (restarts coreaudiod)
scripts/release.sh         # build/AudIO-<version>.dmg
```

The desktop widgets (`Widget/`) are a WidgetKit extension; `scripts/app.sh` builds it the way Xcode would (App Intents metadata, extension entry point) and restarts the widget services on install, so they show the new build.

Translations live in `Resources/Localizable.xcstrings`, `Resources/InfoPlist.xcstrings` and `Widget/Localizable.xcstrings` (String Catalogs, editable in Xcode). To try a language: `open build/AudIO.app --args -AppleLanguages '(de)'`.

Every push to `main` is released: GitHub Actions derives the next semver from [Conventional Commits](https://www.conventionalcommits.org) since the last tag (`feat` → minor, `!`/`BREAKING CHANGE` → major, anything else → patch; see `scripts/version.sh`), builds the `.dmg`, tags it and publishes the release. The version in `Resources/Info.plist` stays `0.0.0` in the repo. Builds are signed with a self-signed certificate so macOS keeps the audio permissions across updates: `scripts/signing.sh setup` creates it once, stores it in 1Password, sets the GitHub secrets and imports it into your keychain (`scripts/signing.sh import` on another Mac). Without it, builds are ad-hoc signed. After changing the driver, bump `CFBundleVersion` in `Driver/Info.plist` so the app offers the update.

## Uninstall

```sh
sudo rm -rf /Applications/AudIO.app /Library/Audio/Plug-Ins/HAL/AudIO.driver && sudo killall coreaudiod
```
