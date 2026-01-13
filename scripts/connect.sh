#!/bin/bash

# Mac2Droid Connection Script
# Sets up ADB port forwarding for USB connection

set -e

PORT=${1:-5555}

echo "Mac2Droid Connection Setup"
echo "=========================="
echo ""

# Check if adb is available
if ! command -v adb &> /dev/null; then
    echo "Error: adb not found in PATH"
    echo "Please install Android SDK platform-tools"
    exit 1
fi

# Check for connected devices
DEVICES=$(adb devices | grep -v "List of devices" | grep -v "^$" | wc -l)

if [ "$DEVICES" -eq 0 ]; then
    echo "Error: No Android devices connected"
    echo "Please connect your device via USB and enable USB debugging"
    exit 1
fi

echo "Found $(echo $DEVICES) device(s)"
echo ""

# Remove existing forward/reverse (if any)
adb forward --remove tcp:$PORT 2>/dev/null || true
adb reverse --remove tcp:$PORT 2>/dev/null || true

# Set up reverse port forwarding (Android localhost -> Mac)
echo "Setting up reverse port forwarding: device:$PORT -> Mac:$PORT"
adb reverse tcp:$PORT tcp:$PORT

if [ $? -eq 0 ]; then
    echo ""
    echo "Success! Port forwarding established."
    echo ""
    echo "Next steps:"
    echo "1. Start Mac2Droid on your Mac"
    echo "2. Click 'Start Streaming'"
    echo "3. Open Mac2Droid app on Android"
    echo "4. Click 'Connect'"
    echo ""
else
    echo "Error: Failed to set up port forwarding"
    exit 1
fi
