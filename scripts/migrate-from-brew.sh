#!/bin/bash
set -euo pipefail

# Migrate agent-deck from Homebrew to direct binary install.
#
# Safe for running while agent-deck sessions are active:
# - tmux sessions are independent of the agent-deck binary
# - The binary is only needed to create/manage sessions, not to keep them alive
# - We swap the binary atomically via mv
#
# After migration, `agent-deck update` pulls from your fork's GitHub releases.

INSTALL_DIR="$HOME/.local/bin"
BINARY="$INSTALL_DIR/agent-deck"

echo "=== agent-deck: migrate from Homebrew to direct binary ==="

# --- Step 1: Locate current install ---
BREW_BIN="$(brew --prefix 2>/dev/null)/bin/agent-deck" || true

if [ ! -x "$BREW_BIN" ]; then
    # Check if brew has it at all
    if ! brew list agent-deck &>/dev/null; then
        echo "Homebrew agent-deck not found. Checking for existing binary..."
        if [ -x "$BINARY" ]; then
            echo "Already installed at $BINARY"
            "$BINARY" version
            echo "Nothing to migrate."
            exit 0
        else
            echo "No agent-deck found. Build from source with: make install-user"
            exit 1
        fi
    fi
    BREW_BIN="$(brew --prefix agent-deck)/bin/agent-deck"
fi

BREW_VERSION="$("$BREW_BIN" version 2>/dev/null || echo "unknown")"
echo "Found Homebrew install: $BREW_BIN ($BREW_VERSION)"

# --- Step 2: Check for running sessions ---
SESSIONS="$(tmux list-sessions 2>/dev/null || true)"
if [ -n "$SESSIONS" ]; then
    echo ""
    echo "Active tmux sessions detected (these will NOT be affected):"
    echo "$SESSIONS"
    echo ""
fi

# --- Step 3: Copy binary to ~/.local/bin ---
mkdir -p "$INSTALL_DIR"

if [ -f "$BINARY" ]; then
    BACKUP="$BINARY.brew-backup"
    echo "Backing up existing $BINARY -> $BACKUP"
    cp "$BINARY" "$BACKUP"
fi

echo "Copying $BREW_BIN -> $BINARY"
cp "$BREW_BIN" "${BINARY}.tmp"
chmod +x "${BINARY}.tmp"
mv "${BINARY}.tmp" "$BINARY"  # atomic replace

# --- Step 4: Verify the copy works ---
if ! "$BINARY" version &>/dev/null; then
    echo "ERROR: copied binary doesn't work. Restoring backup..."
    if [ -f "$BINARY.brew-backup" ]; then
        mv "$BINARY.brew-backup" "$BINARY"
    fi
    exit 1
fi

echo "Installed: $("$BINARY" version)"

# --- Step 5: Verify PATH precedence ---
RESOLVED="$(which agent-deck 2>/dev/null || true)"
if [ "$RESOLVED" != "$BINARY" ]; then
    echo ""
    echo "WARNING: 'agent-deck' resolves to $RESOLVED, not $BINARY"
    echo "Ensure $INSTALL_DIR is BEFORE Homebrew in your PATH."
    echo "Add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# --- Step 6: Remove Homebrew install ---
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

# --- Step 7: Clean up ---
rm -f "$BINARY.brew-backup"

echo ""
echo "=== Migration complete ==="
echo "Binary: $BINARY"
echo "'agent-deck update' will now pull from your fork's GitHub releases."
echo ""
echo "Next: build and install your fork's version:"
echo "  cd <repo> && git checkout local && make install-user"
