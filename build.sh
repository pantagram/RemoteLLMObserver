#!/bin/bash
set -e

APP_NAME="RemoteLLMObserver"
BUILD_DIR=".build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "▶ Building ${APP_NAME}..."

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Compile all Swift sources in one shot
swiftc \
    Sources/Models.swift \
    Sources/ProcessMonitor.swift \
    Sources/TokenParser.swift \
    Sources/SessionWatcher.swift \
    Sources/CodexSessionWatcher.swift \
    Sources/AppDelegate.swift \
    Sources/main.swift \
    -framework AppKit \
    -framework Foundation \
    -framework CoreServices \
    -lsqlite3 \
    -O \
    -o "${BINARY}"

# Bundle the Info.plist
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

echo "✓ Built: ${APP_BUNDLE}"
echo ""
echo "To install:"
echo "  cp -r '${APP_BUNDLE}' ~/Applications/"
echo "  open ~/Applications/${APP_NAME}.app"
echo ""
echo "To run directly:"
echo "  open '${APP_BUNDLE}'"
