#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release
bundle="$project_root/dist/Agent Spotlight.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
binary_path="$(swift build -c release --show-bin-path)"
cp "$binary_path/AgentSpotlight" "$bundle/Contents/MacOS/AgentSpotlight"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Agent Spotlight</string>
<key>CFBundleDisplayName</key><string>Agent Spotlight</string>
<key>CFBundleIdentifier</key><string>local.agent-spotlight.app</string>
<key>CFBundleExecutable</key><string>AgentSpotlight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$bundle"
printf 'Built %s\n' "$bundle"
