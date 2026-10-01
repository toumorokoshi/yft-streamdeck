CC = clang
CFLAGS = -O2 -fobjc-arc -arch arm64 -arch x86_64 -framework Foundation -framework Cocoa -framework IOKit
PLUGIN_ID = com.toumorokoshi.macosmedia.sdPlugin
OPENDECK_PLUGINS_DIR = $(HOME)/Library/Application Support/opendeck/plugins

SOURCES = src/media_controller.m src/streamdeck_plugin.m src/main.m
HEADERS = src/media_controller.h src/streamdeck_plugin.h

.PHONY: all bundle icons test clean install link

all: icons bin/macos-media bundle

bin:
	mkdir -p bin

icons: bin src/generate_icons.m
	$(CC) -framework Cocoa src/generate_icons.m -o bin/generate_icons
	bin/generate_icons icons

bin/macos-media: bin $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(SOURCES) -o bin/macos-media
	chmod +x bin/macos-media

bundle: icons bin/macos-media manifest.json
	rm -rf $(PLUGIN_ID)
	mkdir -p $(PLUGIN_ID)/bin $(PLUGIN_ID)/icons
	cp manifest.json $(PLUGIN_ID)/
	cp bin/macos-media $(PLUGIN_ID)/bin/
	cp -R icons/* $(PLUGIN_ID)/icons/
	cp -R icons/* $(PLUGIN_ID)/
	chmod +x $(PLUGIN_ID)/bin/macos-media
	@echo "Created $(PLUGIN_ID) bundle successfully."

test: bin/macos-media
	bin/macos-media --status
	bin/macos-media --help

link: bundle
	mkdir -p "$(OPENDECK_PLUGINS_DIR)"
	rm -rf "$(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"
	ln -s "$(CURDIR)/$(PLUGIN_ID)" "$(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"
	@echo "Symlinked $(PLUGIN_ID) to $(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"

install: bundle
	mkdir -p "$(OPENDECK_PLUGINS_DIR)"
	rm -rf "$(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"
	cp -R "$(PLUGIN_ID)" "$(OPENDECK_PLUGINS_DIR)/"
	@echo "Installed $(PLUGIN_ID) to $(OPENDECK_PLUGINS_DIR)/$(PLUGIN_ID)"

clean:
	rm -rf bin icons com.toumorokoshi.macosmedia.sdPlugin
