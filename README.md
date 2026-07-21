# Tumoflip Studio

Tumoflip Studio is the unified macOS workspace for Tumoflip firmware, Flipper Zero,
Module One, and Unleashed Companion integrations.

This repository is also the canonical home of TumoCard for macOS. The former
standalone TumoCard Studio app has been consolidated into the **TumoCard**
workspace so NFC CCID access shares the same transport coordination, navigation,
and release lifecycle as the other Tumoflip tools.

## Included workspaces

- **AI & Relay**: AI-provider collection, local HTTP/Bonjour endpoint, BLE App Bridge,
  allowlisted host-command Relay, Claude Buddy relay, and ARF offload transport.
- **TumoCard**: read-only NFC CCID discovery, public ISO 7816 metadata, APDU timeline,
  history, and redacted reports.
- **Network Lab**: Module One / ESP32 Marauder serial monitoring, inventory, findings,
  authorized capture workflow, and reports.
- **FAP Developer**: firmware identity inspection, FAP API compatibility reports, builds,
  and controlled USB launch.
- **Activity**: shared transport and application events.

The application coordinates wired transports so PC/SC, serial, and Flipper USB jobs
cannot claim the same device concurrently. Bluetooth and the local HTTP service can
remain active in the background.

Closing the main window keeps those background services running in the macOS menu bar.
The standard macOS **Quit** action and Command-Q also move the application into this
background state. Use **Open Tumoflip Studio** to restore the window and **Quit Completely**
in the status menu to stop the services and terminate the process. The Dock uses one
canonical icon so it remains identical while the window is open, hidden, or the application
is not running. Light, dark, and Liquid Glass artwork variants are retained in
`Resources/AppIconSources`.

## Build and install

Requirements: macOS 14 or newer and Xcode 16 or a compatible Swift toolchain.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --jobs 2
./script/build_and_run.sh --verify
./script/install_app.sh
```

Regenerate the conventional macOS `AppIcon.icns` from the canonical dark 1024 px source with:

```bash
./script/generate_app_icon.sh
```

The installed bundle is `/Applications/Tumoflip Studio.app`. Local builds are
ad-hoc signed and are not notarized.

Create an installable Apple Silicon beta archive with:

```bash
./script/package_release.sh v0.1.0-beta.1 1
cd dist && shasum -a 256 -c SHA256SUMS
```

The release command writes the app bundle, a versioned ZIP, `SHA256SUMS`, and
`BUILD-METADATA.txt` to `dist/`. The default ad-hoc signature is suitable for
beta testing only. A stable public release still requires Developer ID signing,
Apple notarization, and stapling.

## Configuration

AI Radar defaults to `~/Projects/Flipper/flipper-ai-dashboard`. Override the
collector root with `TUMOFLIP_AI_RADAR_ROOT` and Python with `TUMOFLIP_PYTHON`.
Relay defaults to `~/Projects/Flipper/flipper_relay/mac/commands.local.json`, with
`commands.example.json` as a fallback. Override it with `TUMOFLIP_RELAY_CONFIG`.
The Developer workspace defaults to `~/Projects/Flipper/unleashed-firmware`.

## Safety boundaries

- TumoCard only permits the read-only APDU allowlist inherited from TumoCard Studio.
- Network Lab active operations are intended only for networks you own or are
  explicitly authorized to assess.
- Existing standalone applications remain installed until each migrated workspace
  is accepted in Tumoflip Studio.
