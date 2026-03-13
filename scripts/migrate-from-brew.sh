#!/bin/bash
set -euo pipefail

# Migrate agent-deck from Homebrew to the fork's binary release.
#
# Safe for running while agent-deck sessions are active:
# - tmux sessions are independent of the agent-deck binary
# - The binary is only needed to create/manage sessions, not to keep them alive
# - We swap the binary atomically via mv
#
# After migration, `agent-deck update` pulls from the fork's GitHub releases.

FORK_REPO="johnuopini/agent-deck"
INSTALL_DIR="$HOME/.local/bin"
BINARY="$INSTALL_DIR/agent-deck"

echo "=== agent-deck: migrate from Homebrew to fork binary ==="

# --- Step 1: Detect current install ---
BREW_INSTALLED=false
if command -v brew &>/dev/null && brew list agent-deck &>/dev/null; then
    BREW_BIN="$(brew --prefix 2>/dev/null)/bin/agent-deck"
    BREW_VERSION="$("$BREW_BIN" version 2>/dev/null || echo "unknown")"
    echo "Found Homebrew install: $BREW_BIN ($BREW_VERSION)"
    BREW_INSTALLED=true
elif [ -x "$BINARY" ]; then
    echo "Found existing binary at $BINARY"
    "$BINARY" version
fi

# --- Step 2: Check for running sessions ---
SESSIONS="$(tmux list-sessions 2>/dev/null || true)"
if [ -n "$SESSIONS" ]; then
    echo ""
    echo "Active tmux sessions detected (these will NOT be affected):"
    echo "$SESSIONS"
    echo ""
fi

# --- Step 3: Download fork release ---
echo "Fetching latest release from $FORK_REPO..."
RELEASE_JSON="$(curl -sf "https://api.github.com/repos/$FORK_REPO/releases/latest")"
if [ -z "$RELEASE_JSON" ]; then
    echo "ERROR: No releases found at $FORK_REPO."
    echo "Ensure you have published a release first."
    exit 1
fi

RELEASE_TAG="$(echo "$RELEASE_JSON" | grep '"tag_name"' | sed 's/.*: "\(.*\)".*/\1/')"
RELEASE_VERSION="${RELEASE_TAG#v}"
echo "Latest fork release: $RELEASE_TAG"

# Detect platform
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "ERROR: unsupported architecture: $ARCH"; exit 1 ;;
esac

ASSET_NAME="agent-deck_${RELEASE_VERSION}_${OS}_${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/$FORK_REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"

echo "Downloading $ASSET_NAME..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if ! curl -fSL -o "$TMPDIR/$ASSET_NAME" "$DOWNLOAD_URL"; then
    echo "ERROR: failed to download $DOWNLOAD_URL"
    echo "Available assets:"
    echo "$RELEASE_JSON" | grep '"name"' | grep 'tar.gz' | sed 's/.*: "\(.*\)".*/  \1/'
    exit 1
fi

# --- Step 4: Extract and install ---
echo "Extracting..."
tar -xzf "$TMPDIR/$ASSET_NAME" -C "$TMPDIR"

if [ ! -f "$TMPDIR/agent-deck" ]; then
    echo "ERROR: agent-deck binary not found in archive"
    ls -la "$TMPDIR"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

if [ -f "$BINARY" ]; then
    cp "$BINARY" "$BINARY.backup"
fi

chmod +x "$TMPDIR/agent-deck"
mv "$TMPDIR/agent-deck" "${BINARY}.tmp"
mv "${BINARY}.tmp" "$BINARY"  # atomic replace

# --- Step 5: Verify ---
if ! "$BINARY" version &>/dev/null; then
    echo "ERROR: installed binary doesn't work. Restoring backup..."
    if [ -f "$BINARY.backup" ]; then
        mv "$BINARY.backup" "$BINARY"
    fi
    exit 1
fi

INSTALLED_VERSION="$("$BINARY" version 2>/dev/null)"
echo "Installed: $INSTALLED_VERSION"

# --- Step 6: Verify PATH precedence ---
RESOLVED="$(which agent-deck 2>/dev/null || true)"
if [ "$RESOLVED" != "$BINARY" ]; then
    echo ""
    echo "WARNING: 'agent-deck' resolves to $RESOLVED, not $BINARY"
    echo "Ensure $INSTALL_DIR is BEFORE Homebrew in your PATH."
    echo 'Add to your shell profile:  export PATH="$HOME/.local/bin:$PATH"'
fi

# --- Step 7: Remove Homebrew install ---
if [ "$BREW_INSTALLED" = true ]; then
    echo ""
    read -rp "Remove Homebrew agent-deck and tap? [Y/n] " confirm
    confirm="${confirm:-Y}"
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "Removing brew package..."
        brew uninstall agent-deck 2>/dev/null || true
        echo "Removing brew tap..."
        brew untap asheshgoplani/tap 2>/dev/null || true
        echo "Homebrew cleanup done."
    else
        echo "Skipped Homebrew removal. You can do it later:"
        echo "  brew uninstall agent-deck && brew untap asheshgoplani/tap"
    fi
fi

# --- Step 8: Clean up ---
rm -f "$BINARY.backup"

echo ""
echo "=== Migration complete ==="
echo "Binary: $BINARY"
echo "Version: $INSTALLED_VERSION"
echo "'agent-deck update' will now pull from $FORK_REPO releases."
