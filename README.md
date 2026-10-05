# yft sandbox Stream Deck Plugin for OpenDeck

A native macOS Stream Deck plugin built for [OpenDeck](https://github.com/nekename/OpenDeck) and compatible with Elgato Stream Deck. It provides macOS media controls, global microphone input mute control with live status display, and Microsoft Teams mute and camera controls.

## Features

- Microphone mute control:
  - Toggles macOS system input volume between 0% and 100%.
  - Mutes microphone input globally across Microsoft Teams, Zoom, Slack, Google Meet, and browser calls.
  - Displays real-time status indicators with 0% (muted) and 100% (live) on the Stream Deck key.
  - Updates dynamically via CoreAudio hardware listeners and WebSocket messages.
  - Restores the previous non-zero volume level when unmuting.
- Microsoft Teams meeting control:
  - Teams Mute toggles the Teams microphone in the current meeting.
  - Teams Camera toggles the Teams camera in the current meeting.
  - Keys show live state pushed by Teams, including changes made in the Teams window.
  - Keys show "No mtg" outside a meeting and "No Teams" when the Teams API is unreachable.
  - Uses the Teams third-party app API on `ws://127.0.0.1:8124`, so Teams does not need focus.
- Media playback control:
  - Play and pause toggle action dynamically updates key state between play and pause.
  - Controls active media sessions across Spotify, Apple Music, YouTube in Safari and Chrome, Podcasts, VLC, and IINA.
  - Dedicated individual actions for Play, Pause, Next Track, and Previous Track.
  - Responds immediately to system playback notifications from macOS MediaRemote.
- Native universal binary:
  - Written in Rust with Tokio and CoreAudio / MediaRemote FFI.
  - Compiled as a universal Mach-O binary supporting arm64 and x86_64 architectures.
  - Requires no Node.js or Python runtime at execution time.
- Fallback support:
  - Media controls use MediaRemote with AppleScript and auxiliary media key fallbacks.
  - Audio input controls use CoreAudio scalar properties with AppleScript fallbacks.

## Installation

The plugin installs into the OpenDeck application support directory.

- Build and symlink the bundle for development:
  - Run `./install.sh --link` or `make link`.
- Copy installation:
  - Run `./install.sh` or `make install`.
- OpenDeck configuration:
  - Launch OpenDeck.
  - Locate the yft sandbox category in the actions list.
  - Drag the Mic Mute action or Play / Pause action to any Stream Deck key.

## Microsoft Teams setup

The Teams actions require the Teams third-party app API.

- Enable the API:
  - Open Teams, then Settings > Privacy > Manage API, and turn on "Enable API".
- Pair the plugin:
  - Join a meeting and press a Teams Mute or Teams Camera key.
  - Teams prompts to allow the new device; select Allow.
  - The pairing token is saved to `~/Library/Application Support/yft-sandbox/teams_token` and reused afterward.

## Standalone CLI commands

The compiled binary can be tested standalone from the command line.

- Microphone control commands:
  - `bin/macos-media --mic-status` prints the current microphone volume and mute state in JSON.
  - `bin/macos-media --toggle-mic` toggles microphone input volume between 0% and restored level.
  - `bin/macos-media --mute` sets input volume to 0%.
  - `bin/macos-media --unmute` restores input volume to previous level or 100%.
- Microsoft Teams commands:
  - `bin/macos-media --teams-status` prints the current Teams meeting state in JSON.
  - `bin/macos-media --toggle-teams-camera` toggles the Teams camera.
  - `bin/macos-media --toggle-teams-mute` toggles the Teams microphone mute.
- Media playback commands:
  - `bin/macos-media --status` prints current media playback state in JSON.
  - `bin/macos-media --toggle` toggles media play and pause.
  - `bin/macos-media --play` starts playback.
  - `bin/macos-media --pause` pauses playback.
  - `bin/macos-media --next` skips to next track.
  - `bin/macos-media --previous` returns to previous track.
  - `bin/macos-media --help` displays all available CLI flags.

## Integration tests

A mock WebSocket server test simulates the OpenDeck lifecycle.

- Run the test suite:
  - Run `python3 tests/mock_opendeck_test.py`.
  - The script tests WebSocket handshake, registration, willAppear, keyDown, setState, setTitle, and willDisappear events for media, microphone, and Teams actions.
  - Teams actions run against a mock Teams API server via the `YFT_TEAMS_API_URL` and `YFT_TEAMS_TOKEN_PATH` overrides.

## Repository layout

- [Makefile](Makefile): build, bundle, test, and install targets.
- [install.sh](install.sh): installer script supporting copy and symlink modes.
- [manifest.json](manifest.json): OpenDeck and Stream Deck plugin manifest definition.
- [Cargo.toml](Cargo.toml): Rust package configuration and dependencies.
- [src/main.rs](src/main.rs): command line entry point and argument parsing.
- [src/audio.rs](src/audio.rs): CoreAudio microphone volume and mute implementation.
- [src/media.rs](src/media.rs): MediaRemote playback controller implementation.
- [src/teams.rs](src/teams.rs): Microsoft Teams third-party app API client.
- [src/plugin.rs](src/plugin.rs): Stream Deck WebSocket client and event handling.
- [objc/generate_icons.m](objc/generate_icons.m): Cocoa generator producing SVG, 72x72 PNG, 128x128 PNG, and 144x144 PNG icon assets.
- [objc/](objc/): original Objective-C implementation preserved for reference.
- [icons/](icons/): generated icon assets.
- [tests/mock_opendeck_test.py](tests/mock_opendeck_test.py): integration test suite.
- [com.toumorokoshi.yftsandbox.sdPlugin/](com.toumorokoshi.yftsandbox.sdPlugin/): distributable plugin bundle.

## Icon licensing

- Icon glyphs are sourced from Phosphor Icons, licensed under the MIT License.
- Assets include plugin badges and high-contrast status tiles for media, microphone, and Teams actions.
- License text is included in [icons/LICENSE](icons/LICENSE).

## References

- OpenDeck project repository: https://github.com/nekename/OpenDeck
- Elgato Stream Deck Plugin SDK documentation: https://docs.elgato.com/sdk/plugins/overview
- Phosphor Icons: https://phosphoricons.com
