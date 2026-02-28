#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_run() {
    echo -e "${BLUE}$*${NC}"
    "$@"
}

INSTALL=false
while getopts "i" opt; do
    case $opt in
        i) INSTALL=true ;;
        *) echo "Usage: $0 [-i]"; exit 1 ;;
    esac
done

# Check Xcode is available (works regardless of app name or install location)
if ! xcodebuild -version &>/dev/null; then
    echo -e "${RED}xcodebuild not found. Make sure Xcode.app is installed and selected:${NC}"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

if ! command -v xcodegen &>/dev/null; then
    echo -e "${RED}xcodegen not found. Install it with: brew install xcodegen${NC}"
    exit 1
fi

if [ ! -f local.yml ]; then
    cp local.yml.example local.yml
    echo -e "${BLUE}Created local.yml from local.yml.example (add your DEVELOPMENT_TEAM)${NC}"
fi

echo_run xcodegen generate

SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git status --porcelain 2>/dev/null | grep -q . && echo "-dirty" || echo "")
VERSION="${SHA}${DIRTY}"
echo -e "${BLUE}Version: ${VERSION}${NC}"

XCODEBUILD_ARGS=(-project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageApp -configuration Release -derivedDataPath build
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION")

echo -e "${BLUE}xcodebuild ${XCODEBUILD_ARGS[*]} build${NC}"
xcodebuild "${XCODEBUILD_ARGS[@]}" build 2>&1 | grep -E "^(error:|warning:|note:|Build|.*FAILED|.*SUCCEEDED)" || true

APP_PATH=$(find build -name "TokenEater.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo -e "${RED}Build failed. Run with full output:${NC}"
    echo "  xcodebuild ${XCODEBUILD_ARGS[*]} build"
    exit 1
fi

echo ""
echo -e "${GREEN}Build succeeded!${NC}"
echo -e "App: ${BLUE}$APP_PATH${NC}"

if $INSTALL; then
    echo ""
    pkill -x TokenEater 2>/dev/null || true
    echo_run cp -R "$APP_PATH" /Applications/
    echo_run open /Applications/TokenEater.app
    echo -e "${GREEN}Installed and started — check your menu bar.${NC}"
else
    echo ""
    echo "To install and launch:"
    echo "  cp -R \"$APP_PATH\" /Applications/ && open /Applications/TokenEater.app"
fi
