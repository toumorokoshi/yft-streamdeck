#!/usr/bin/env bash
set -e

PLUGIN_NAME="com.toumorokoshi.macosmedia.sdPlugin"
OPENDECK_DIR="$HOME/Library/Application Support/opendeck"
PLUGINS_DIR="$OPENDECK_DIR/plugins"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="copy"
if [[ "$1" == "--link" || "$1" == "-l" ]]; then
    MODE="link"
fi

echo "=== Installing macOS Media Plugin for OpenDeck ==="

# Build bundle if needed
cd "$SCRIPT_DIR"
if [[ ! -d "$PLUGIN_NAME" || ! -f "$PLUGIN_NAME/bin/macos-media" ]]; then
    echo "Building plugin bundle..."
    make bundle
fi

# Ensure OpenDeck plugins directory exists
mkdir -p "$PLUGINS_DIR"

DEST="$PLUGINS_DIR/$PLUGIN_NAME"

if [[ -e "$DEST" || -L "$DEST" ]]; then
    echo "Removing existing installation at $DEST..."
    rm -rf "$DEST"
fi

if [[ "$MODE" == "link" ]]; then
    echo "Creating symlink to development directory..."
    ln -s "$SCRIPT_DIR/$PLUGIN_NAME" "$DEST"
    echo "Linked: $DEST -> $SCRIPT_DIR/$PLUGIN_NAME"
else
    echo "Copying plugin bundle to OpenDeck plugins directory..."
    cp -R "$SCRIPT_DIR/$PLUGIN_NAME" "$DEST"
    echo "Installed to: $DEST"
fi

echo ""
echo "Plugin installed successfully!"
echo "If OpenDeck is currently running, restart it to load the plugin."
