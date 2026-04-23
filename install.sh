#!/usr/bin/env bash
#
# HandsFree one-shot installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Harikrishnareddyl/hands_free/main/install.sh | bash
#
# What it does:
#   1. Downloads the latest HandsFree DMG from GitHub Releases.
#   2. Mounts the DMG silently, copies HandsFree.app into /Applications,
#      then unmounts.
#   3. Launches HandsFree.
#
# Belt-and-braces: we also strip com.apple.quarantine from the installed
# bundle. For the official signed + notarized releases this is a no-op,
# but if someone ever ships an ad-hoc fork the fallback keeps working.

set -euo pipefail

REPO="Harikrishnareddyl/hands_free"
APP_NAME="HandsFree"
DEST="/Applications/${APP_NAME}.app"

# Pretty output helpers — fall back gracefully if not a TTY.
if [[ -t 1 ]]; then
    bold=$(printf '\033[1m')
    dim=$(printf '\033[2m')
    green=$(printf '\033[32m')
    red=$(printf '\033[31m')
    reset=$(printf '\033[0m')
else
    bold=""; dim=""; green=""; red=""; reset=""
fi

step()  { printf "${bold}→${reset} %s\n" "$1"; }
info()  { printf "${dim}  %s${reset}\n" "$1"; }
ok()    { printf "${green}✓${reset} %s\n" "$1"; }
die()   { printf "${red}✗ %s${reset}\n" "$1" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------

[[ "$(uname)" == "Darwin" ]] || die "HandsFree is macOS only."

os_major=$(sw_vers -productVersion | cut -d. -f1)
if (( os_major < 13 )); then
    die "HandsFree requires macOS 13 (Ventura) or later. You have $(sw_vers -productVersion)."
fi

for bin in curl hdiutil xattr; do
    command -v "$bin" >/dev/null 2>&1 || die "Missing required tool: $bin"
done

# --- Find latest release asset ----------------------------------------------

step "Looking up latest release"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

# Grab just the browser_download_url for a .dmg asset. No jq dep.
DMG_URL=$(curl -fsSL "$API_URL" \
    | grep -o 'https://[^"]*HandsFree-[^"]*\.dmg' \
    | head -1 || true)

[[ -n "$DMG_URL" ]] || die "Could not find a DMG in the latest release at $API_URL"

VERSION=$(echo "$DMG_URL" | sed -E 's|.*HandsFree-([^/]+)\.dmg|\1|')
info "Found HandsFree ${VERSION}"

# --- Download ---------------------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

DMG_PATH="$TMP/HandsFree.dmg"

step "Downloading DMG"
info "$DMG_URL"
curl -#Lf "$DMG_URL" -o "$DMG_PATH"
size=$(du -h "$DMG_PATH" | cut -f1)
info "Downloaded ${size}"

# --- Mount + copy -----------------------------------------------------------

step "Mounting DMG"
# -quiet suppresses the mount-point line we need to capture, so don't pass it.
MOUNT_OUTPUT=$(hdiutil attach "$DMG_PATH" -nobrowse -readonly 2>&1)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
[[ -n "$MOUNT_POINT" ]] || die "Failed to mount DMG: $MOUNT_OUTPUT"

cleanup_mount() { hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup_mount EXIT

SRC="$MOUNT_POINT/${APP_NAME}.app"
[[ -d "$SRC" ]] || die "HandsFree.app not found inside the DMG at $SRC"

# If a previous copy is running, quit it so we can overwrite the bundle.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    step "Quitting running HandsFree"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

step "Installing to /Applications"
if [[ -d "$DEST" ]]; then
    info "Removing previous install"
    rm -rf "$DEST" 2>/dev/null || {
        info "Need sudo to replace the existing /Applications/${APP_NAME}.app"
        sudo rm -rf "$DEST"
    }
fi

# ditto preserves metadata, extended attrs, and resource forks better than cp -R.
if ! ditto "$SRC" "$DEST" 2>/dev/null; then
    info "Need sudo to write into /Applications"
    sudo ditto "$SRC" "$DEST"
fi

xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # no-op for notarized, keeps ad-hoc forks working

step "Verifying code signature"
if codesign --verify --strict "$DEST" >/dev/null 2>&1; then
    ok "Signature valid"
else
    info "Signature check failed — bundle may be an ad-hoc dev build."
fi

# --- Launch -----------------------------------------------------------------

step "Launching HandsFree"
open "$DEST"

echo
ok "HandsFree ${VERSION} installed to ${DEST}"
info "Menu bar → mic icon → Settings… to add your Groq API key."
info "Then hold Fn (🌐) or ⌃⌥D and speak."
