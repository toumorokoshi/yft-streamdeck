CC = clang
PLUGIN_ID = com.toumorokoshi.yftsandbox.sdPlugin
LEGACY_PLUGIN_ID = com.toumorokoshi.macosmedia.sdPlugin
OPENDECK_PLUGINS_DIR = $(HOME)/Library/Application Support/opendeck/plugins

RUST_SOURCES = src/main.rs src/audio.rs src/media.rs src/plugin.rs Cargo.toml

.PHONY: all bundle icons test clean install link

all: icons bin/macos-media bundle

bin:
	mkdir -p bin

icons: bin objc/generate_icons.m
	$(CC) -framework Cocoa objc/generate_icons.m -o bin/generate_icons
	bin/generate_icons icons

bin/macos-media: bin $(RUST_SOURCES)
	cargo build --release --target aarch64-apple-darwin
	cargo build --release --target x86_64-apple-darwin
	lipo -create \
		target/aarch64-apple-darwin/release/macos-media \
		target/x86_64-apple-darwin/release/macos-media \
		-output bin/macos-media
	chmod +x bin/macos-media

bundle: icons bin/macos-media manifest.json
	rm -rf $(PLUGIN_ID) $(LEGACY_PLUGIN_ID)
	mkdir -p $(PLUGIN_ID)/bin $(PLUGIN_ID)/icons
	cp manifest.json $(PLUGIN_ID)/
	cp bin/macos-media $(PLUGIN_ID)/bin/
	cp -R icons/* $(PLUGIN_ID)/icons/
	cp -R icons/* $(PLUGIN_ID)/
	chmod +x $(PLUGIN_ID)/bin/macos-media
	@echo "Created $(PLUGIN_ID) bundle successfully."

test: bin/macos-media
	bin/macos-media --status
	bin/macos-media --mic-status
	bin/macos-media --help
	python3 tests/mock_opendeck_test.py

link: bundle
	mkdir -p "$(OPENDECK_PLUGINS_DIR)"
	rm -rf "$(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)" "$(OPENDECK_PLUGINS_DIR)/$(LEGACY_PLUGIN_ID)"
	ln -s "$(CURDIR)/$(PLUGIN_ID)" "$(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"
	@echo "Symlinked $(PLUGIN_ID) to $(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"

install: bundle
	mkdir -p "$(OPENDECK_PLUGINS_DIR)"
	rm -rf "$(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)" "$(OPENDECK_PLUGINS_DIR)/$(LEGACY_PLUGIN_ID)"
	cp -R "$(PLUGIN_ID)" "$(OPENDECK_PLUGINS_DIR)/"
	@echo "Installed $(PLUGIN_ID) to $(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"

clean:
	cargo clean
	rm -rf bin icons $(PLUGIN_ID) $(LEGACY_PLUGIN_ID)

