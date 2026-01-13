#!/bin/bash
# Mac2Droid Build & Sign Script

set -e
cd /Users/grkndev/Desktop/repo/mac2droid/mac-server

echo "🔨 Building Mac2Droid..."
xcodebuild -project Mac2Droid.xcodeproj -scheme Mac2Droid -configuration Debug build 2>&1 | grep -E "(error:|BUILD)"

echo ""
echo "📦 Updating app..."
pkill -f "Mac2Droid" 2>/dev/null || true
sleep 1

# Copy to Applications
cp -r ~/Library/Developer/Xcode/DerivedData/Mac2Droid-*/Build/Products/Debug/Mac2Droid.app /Applications/

echo "🔐 Signing with Mac2Droid Dev certificate..."
codesign --force --deep --sign "Mac2Droid Dev" /Applications/Mac2Droid.app

echo ""
echo "🚀 Launching Mac2Droid..."
open /Applications/Mac2Droid.app

echo ""
echo "✅ Done!"
