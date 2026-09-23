<p align="center"><img src="Resources/Icon.png" width="128" alt="AudIO icon"></p>

# AudIO

Play your Mac's audio on several outputs at once (e.g. MacBook speakers + a Bluetooth speaker), each with its own delay and level, kept in sync.

AudIO adds an **AudIO** device to the Sound menu. Select it to start routing, pick another device to stop. The volume keys control the master.

Requires macOS 14.2 or later on Apple Silicon.

## Install

1. Download the latest `.dmg` from [Releases](../../releases) and drag AudIO to Applications.
2. The app isn't notarized, so macOS blocks it on first launch. Open **System Settings › Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/AudIO.app`.
3. Click **Install audio device** in the menu bar popover (asks for your password), then allow system audio recording when prompted.

## Use

- Tick the outputs to play on. Each gets a **Level** and a **Delay** slider.
- **Measure delays** plays short test tones through each output and uses the microphone to align them. Keep the room quiet and the Mac near your listening position.

## Build

Requires Xcode 26.

```sh
scripts/app.sh run         # build and launch build/AudIO.app (driver bundled)
scripts/driver.sh install  # install the driver directly (restarts coreaudiod)
scripts/release.sh         # build/AudIO-<version>.dmg
```

Every push to `main` is released: GitHub Actions derives the next semver from [Conventional Commits](https://www.conventionalcommits.org) since the last tag (`feat` → minor, `!`/`BREAKING CHANGE` → major, anything else → patch; see `scripts/version.sh`), builds the `.dmg`, tags it and publishes the release. The version in `Resources/Info.plist` stays `0.0.0` in the repo. Builds are ad-hoc signed; set `CODESIGN_IDENTITY` to a self-signed code-signing certificate so macOS keeps your permissions across rebuilds. After changing the driver, bump `CFBundleVersion` in `Driver/Info.plist` so the app offers the update.

## Uninstall

```sh
sudo rm -rf /Applications/AudIO.app /Library/Audio/Plug-Ins/HAL/AudIO.driver && sudo killall coreaudiod
```
