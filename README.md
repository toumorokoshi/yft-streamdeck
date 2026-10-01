# macOS Media Stream Deck Plugin for OpenDeck

A native macOS Stream Deck plugin built for [OpenDeck](https://github.com/nekename/OpenDeck) (and compatible with Elgato Stream Deck). It provides system-wide media playback control on macOS with real-time playback state synchronization.

---

## Features

- **Play / Pause Toggle Button**:
  - Dynamically updates its key icon in real time: shows **Play (▶)** when media is paused, and **Pause (⏸)** when media is currently playing.
  - Controls Spotify, Apple Music, YouTube in Safari/Chrome, Podcasts, VLC, IINA, and any other application registered with macOS Now Playing.
  - Responds immediately to hardware keys, Bluetooth headphones, or on-screen actions via system notifications.
- **Dedicated Actions**:
  - **Play**: Explicitly resume / start media playback.
  - **Pause**: Explicitly pause media playback.
  - **Next Track**: Skip to the next track.
  - **Previous Track**: Return to the previous track.
- **100% Native Universal Binary**:
  - Built with Objective-C and Cocoa — zero external dependencies, no Node.js or Python runtime required at execution time.
  - Compiled as a universal Mach-O binary supporting both Apple Silicon (`arm64`) and Intel (`x86_64`).
- **Resilient Fallback**:
  - Primary control via macOS `MediaRemote.framework` (identical to macOS Control Center).
  - Secondary fallback via AppleScript and system auxiliary media keys (`NX_KEYTYPE_PLAY`) to ensure reliable playback start even when no active Now Playing session exists.

---

## Quick Start & Installation

The plugin is designed to be installed into OpenDeck's plugin directory:
`~/Library/Application Support/opendeck/plugins/com.toumorokoshi.macosmedia.sdPlugin`

### 1. Build and Link (Recommended for Development)

Run the install script with `--link` to symlink the bundle into OpenDeck:

```bash
./install.sh --link
```

Or using `make`:

```bash
make link
```

### 2. Copy Installation

To copy the bundle instead of symlinking:

```bash
./install.sh
```

Or:

```bash
make install
```

### 3. Open OpenDeck

1. Launch or restart **OpenDeck**.
2. Look for the **Media** category in the OpenDeck actions panel.
3. Drag the **Play / Pause** action onto any Stream Deck key.
4. Press the key to toggle your media!

---

## Standalone CLI Testing

You can test the binary directly without running OpenDeck:

```bash
# Query playback status (outputs JSON)
bin/macos-media --status

# Toggle play/pause
bin/macos-media --toggle

# Explicit commands
bin/macos-media --play
bin/macos-media --pause
bin/macos-media --next
bin/macos-media --previous

# View all options
bin/macos-media --help
```

---

## Integration Test Suite

A mock WebSocket server test simulates the OpenDeck lifecycle (registration, `willAppear`, `keyDown`, `setState`, and shutdown):

```bash
python3 tests/mock_opendeck_test.py
```

---

## Project Structure

```
├── Makefile                           # Build, bundle, test, and install targets
├── install.sh                         # Interactive / automated installer
├── manifest.json                      # OpenDeck / Stream Deck plugin manifest
├── src/
│   ├── main.m                         # Plugin entrypoint & argument parsing
│   ├── media_controller.h/m           # MediaRemote & system media controller
│   ├── streamdeck_plugin.h/m          # WebSocket client & event router
│   └── generate_icons.m               # Cocoa script generating 72x72 & 144x144 PNGs
├── icons/                             # Generated icon assets (standard and @2x)
├── tests/
│   └── mock_opendeck_test.py          # Mock OpenDeck WebSocket server test
└── com.toumorokoshi.macosmedia.sdPlugin/ # Distributable plugin bundle
    ├── manifest.json
    ├── bin/macos-media
    └── icons/
```

---

## Icons & Licensing

The icons in this plugin are built using vector glyphs from **[Phosphor Icons](https://phosphoricons.com/)** (the same icon library OpenDeck uses), licensed under the **MIT License**.

- **Plugin Icon**: Vibrant purple/indigo badge with white music notes (`plugin.svg`, `plugin.png`, `plugin@2x.png`, `plugin_128.png`).
- **Action Icons**: High-contrast `#22222A` dark rounded tiles with `#FFFFFF` crisp white vector glyphs for:
  - Play / Pause (`playpause`)
  - Play (`play`)
  - Pause (`pause`)
  - Next Track (`next`)
  - Previous Track (`previous`)
- Delivered as both `.svg` vector files and `.png` raster files (72x72, 128x128, and 144x144 @2x Retina) to ensure compatibility with all OpenDeck and Stream Deck display contexts.

---

## License

- Plugin Code: MIT License (see [LICENSE](LICENSE))
- Icon Assets: Phosphor Icons (MIT License, Copyright (c) 2023 Phosphor Icons, see [icons/LICENSE](icons/LICENSE))
