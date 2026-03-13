#!/bin/bash
set -euo pipefail

# Install or update agent-deck from the fork's GitHub releases.
#
# Idempotent — run this whenever you want to sync with the fork's latest release.
# Handles: fresh install, brew migration, and updates from older fork releases.
#
# Safe while agent-deck sessions are running (tmux sessions are independent
# of the binary — we swap atomically via mv).

FORK_REPO="johnuopini/agent-deck"
UPSTREAM_REPO="asheshgoplani/agent-deck"
INSTALL_DIR="$HOME/.local/bin"
BINARY="$INSTALL_DIR/agent-deck"

echo "=== agent-deck fork-setup ==="

# --- Detect platform ---
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)         ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    *)  echo "ERROR: unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Platform: ${OS}/${ARCH}"

# --- Detect current install ---
CURRENT_VERSION=""
CURRENT_BIN=""
BREW_INSTALLED=false

if command -v brew &>/dev/null && brew list agent-deck &>/dev/null; then
    BREW_INSTALLED=true
    CURRENT_BIN="$(brew --prefix 2>/dev/null)/bin/agent-deck"
    CURRENT_VERSION="$("$CURRENT_BIN" version 2>/dev/null | sed 's/Agent Deck v//' || echo "")"
    echo "Found: Homebrew install ($CURRENT_VERSION) at $CURRENT_BIN"
elif [ -x "$BINARY" ]; then
    CURRENT_BIN="$BINARY"
    CURRENT_VERSION="$("$BINARY" version 2>/dev/null | sed 's/Agent Deck v//' || echo "")"
    echo "Found: direct install ($CURRENT_VERSION) at $BINARY"
else
    echo "No existing agent-deck found — fresh install."
fi

# --- Check if current install is upstream (no -franz suffix) ---
if [ -n "$CURRENT_VERSION" ]; then
    case "$CURRENT_VERSION" in
        *-franz*)
            echo "Running fork release: $CURRENT_VERSION"
            ;;
        *)
            echo "Running upstream release: $CURRENT_VERSION"
            ;;
    esac
fi

# --- Fetch latest fork release ---
echo ""
echo "Checking $FORK_REPO for latest release..."
RELEASE_JSON="$(curl -sf "https://api.github.com/repos/$FORK_REPO/releases/latest" || true)"
if [ -z "$RELEASE_JSON" ]; then
    echo "ERROR: no releases found at $FORK_REPO"
    echo "Push a tag and run goreleaser first."
    exit 1
fi

RELEASE_TAG="$(echo "$RELEASE_JSON" | grep '"tag_name"' | sed 's/.*: "\(.*\)".*/\1/')"
RELEASE_VERSION="${RELEASE_TAG#v}"
echo "Latest fork release: $RELEASE_TAG"

# --- Compare versions ---
if [ "$CURRENT_VERSION" = "$RELEASE_VERSION" ]; then
    echo "Already on latest fork release. Nothing to do."
    exit 0
fi

if [ -n "$CURRENT_VERSION" ]; then
    echo "Will update: $CURRENT_VERSION -> $RELEASE_VERSION"
else
    echo "Will install: $RELEASE_VERSION"
fi

# --- Show active sessions ---
SESSIONS="$(tmux list-sessions 2>/dev/null || true)"
if [ -n "$SESSIONS" ]; then
    echo ""
    echo "Active tmux sessions (will NOT be affected):"
    echo "$SESSIONS"
fi

# --- Download ---
ASSET_NAME="agent-deck_${RELEASE_VERSION}_${OS}_${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/$FORK_REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"

echo ""
echo "Downloading $ASSET_NAME..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if ! curl -fSL -o "$TMPDIR/$ASSET_NAME" "$DOWNLOAD_URL"; then
    echo "ERROR: download failed: $DOWNLOAD_URL"
    exit 1
fi

# --- Extract ---
tar -xzf "$TMPDIR/$ASSET_NAME" -C "$TMPDIR"
if [ ! -f "$TMPDIR/agent-deck" ]; then
    echo "ERROR: agent-deck binary not found in archive"
    exit 1
fi

# --- Install ---
mkdir -p "$INSTALL_DIR"
chmod +x "$TMPDIR/agent-deck"

# Atomic swap (works even if binary is running)
cp "$TMPDIR/agent-deck" "${BINARY}.new"
mv "${BINARY}.new" "$BINARY"

# --- Verify ---
INSTALLED_VERSION="$("$BINARY" version 2>/dev/null | sed 's/Agent Deck v//' || echo "unknown")"
echo "Installed: $INSTALLED_VERSION"

if [ "$INSTALLED_VERSION" != "$RELEASE_VERSION" ]; then
    echo "WARNING: version mismatch — expected $RELEASE_VERSION, got $INSTALLED_VERSION"
fi

# --- PATH check ---
RESOLVED="$(command -v agent-deck 2>/dev/null || true)"
if [ "$RESOLVED" != "$BINARY" ]; then
    echo ""
    echo "WARNING: 'agent-deck' resolves to $RESOLVED, not $BINARY"
    echo "Ensure $INSTALL_DIR is first in your PATH:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

# --- Brew cleanup ---
if [ "$BREW_INSTALLED" = true ]; then
    echo ""
    read -rp "Remove Homebrew agent-deck and tap? [Y/n] " confirm
    confirm="${confirm:-Y}"
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        brew uninstall agent-deck 2>/dev/null || true
        brew untap "$UPSTREAM_REPO" 2>/dev/null || true
        brew untap asheshgoplani/tap 2>/dev/null || true
        echo "Homebrew cleanup done."
    else
        echo "Skipped. Remove later: brew uninstall agent-deck && brew untap asheshgoplani/tap"
    fi
fi

# --- Upstream sync reminder ---
echo ""
echo "=== Done ==="
echo "Binary: $BINARY ($INSTALLED_VERSION)"
echo ""
echo "To sync upstream changes into your fork:"
echo "  cd $(pwd) && git fetch upstream && git checkout main && git merge upstream/main"
echo "  git checkout local && git rebase main && make install-user"
