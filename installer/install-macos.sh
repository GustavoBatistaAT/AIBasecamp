#!/usr/bin/env bash
# Basecamp MCP — macOS Installer
#
# Mirrors the Windows installer (setup.iss + install_helper.ps1):
#   1. Python 3.10+             ── required to run the MCP server
#   2. Claude Desktop            ── the MCP client
#   3. Basecamp CLI (darwin)     ── from the official 37signals GitHub release
#   4. Isolated venv + 'mcp' pkg ── no system-Python pollution (PEP 668 safe)
#   5. Claude Desktop config     ── registers the basecamp MCP server + pins account_id
#   6. basecamp auth login       ── browser OAuth flow
#
# Run from the repo root:   bash installer/install-macos.sh
# Or from anywhere:         bash /path/to/repo/installer/install-macos.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="Basecamp AI Assistant"
INSTALL_DIR="$HOME/Library/Application Support/BasecampMCP"
CLAUDE_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CONFIG="$CLAUDE_DIR/claude_desktop_config.json"
# Where to fetch the server script from when running standalone (curl | bash).
# TEMPORARY: points at the feat/macos-installer branch during pre-release validation.
# Flip this to /main once the PR is merged.
RAW_BASE="${BASECAMP_INSTALLER_RAW_BASE:-https://raw.githubusercontent.com/GustavoBatistaAT/AIBasecamp/feat/macos-installer}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { printf "[BasecampMCP] %s\n" "$*"; }
err() { printf "[BasecampMCP] ERROR: %s\n" "$*" >&2; }

ask_yn() {
    local prompt="$1" ans
    # Read from /dev/tty so prompts work under `bash -c "$(curl ...)"`,
    # where stdin is the -c command text (already EOF), not the terminal.
    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt [y/N] " ans < /dev/tty
    else
        read -r -p "$prompt [y/N] " ans
    fi
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Detect architecture — used to pick the right Basecamp CLI asset
case "$(uname -m)" in
    arm64)   ARCH="arm64" ;;
    x86_64)  ARCH="amd64" ;;
    *)       err "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

# Locate the server script — either from a local repo clone, or fetched from GitHub
# (standalone mode, when run via `bash -c "$(curl ...)"`).
SERVER_SCRIPT_SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATE="$SCRIPT_DIR/../app/basecamp_mcp_server.py"
    if [[ -f "$CANDIDATE" ]]; then
        SERVER_SCRIPT_SRC="$(cd "$(dirname "$CANDIDATE")" && pwd)/$(basename "$CANDIDATE")"
    fi
fi

if [[ -z "$SERVER_SCRIPT_SRC" ]]; then
    log "Standalone mode — fetching server script from $RAW_BASE"
    SERVER_SCRIPT_SRC="$(mktemp -t basecamp_mcp_server).py"
    if ! curl -fsSL "$RAW_BASE/app/basecamp_mcp_server.py" -o "$SERVER_SCRIPT_SRC"; then
        err "Failed to download $RAW_BASE/app/basecamp_mcp_server.py"
        exit 1
    fi
fi

# ── PHASE 1: Python ───────────────────────────────────────────────────────────
find_python() {
    local cmd ver
    for cmd in python3.12 python3.11 python3.10 python3; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        ver=$("$cmd" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)
        case "$ver" in
            3.10|3.11|3.12|3.13) command -v "$cmd"; return 0 ;;
        esac
    done
    return 1
}

phase_python() {
    if PY=$(find_python); then
        log "Python $("$PY" --version 2>&1 | awk '{print $2}') at $PY"
        return 0
    fi

    log "Python 3.10+ not found."

    if command -v brew >/dev/null 2>&1; then
        if ask_yn "Install Python 3.12 via Homebrew?"; then
            brew install python@3.12
        else
            err "Python 3.10+ is required. Install from python.org or: brew install python@3.12"
            exit 1
        fi
    else
        err "Python 3.10+ is required."
        err "Either install from https://www.python.org/downloads/macos/"
        err "or install Homebrew first: https://brew.sh and then: brew install python@3.12"
        exit 1
    fi

    PY=$(find_python) || { err "Python install did not complete."; exit 1; }
    log "Python installed at $PY"
}

# ── PHASE 2: Claude Desktop ───────────────────────────────────────────────────
phase_claude() {
    if [[ -d "/Applications/Claude.app" || -d "$HOME/Applications/Claude.app" ]]; then
        log "Claude Desktop already installed."
        mkdir -p "$CLAUDE_DIR"
        return 0
    fi

    log "Claude Desktop not found."
    if ! ask_yn "Install Claude Desktop now?"; then
        err "Claude Desktop is required. Install from https://claude.ai/download and re-run."
        exit 1
    fi

    if command -v brew >/dev/null 2>&1; then
        log "Installing Claude Desktop via Homebrew Cask..."
        if brew install --cask claude; then
            mkdir -p "$CLAUDE_DIR"
            log "Claude Desktop installed."
            return 0
        fi
        log "Homebrew install failed — falling back to manual download."
    fi

    err "Please download Claude Desktop manually from https://claude.ai/download"
    err "Then re-run this installer."
    command -v open >/dev/null && open "https://claude.ai/download" || true
    exit 1
}

# ── PHASE 3: Basecamp CLI ─────────────────────────────────────────────────────
phase_basecamp() {
    log "Fetching latest Basecamp CLI release for darwin_${ARCH}..."
    local asset_url
    asset_url=$(
        curl -fsSL -H "User-Agent: BasecampMCP-Installer" \
            "https://api.github.com/repos/basecamp/basecamp-cli/releases/latest" \
        | "$PY" -c "
import json, re, sys
data = json.load(sys.stdin)
pat = re.compile(r'basecamp_.*_darwin_${ARCH}\.(tar\.gz|zip)$')
for a in data.get('assets', []):
    if pat.search(a['name']):
        print(a['browser_download_url'])
        break
"
    )

    if [[ -z "$asset_url" ]]; then
        err "No Basecamp CLI release found for darwin_${ARCH}."
        exit 1
    fi

    local tmpdir archive bin
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    archive="$tmpdir/basecamp.archive"
    log "Downloading $(basename "$asset_url")..."
    curl -fL --progress-bar -o "$archive" "$asset_url"

    log "Extracting..."
    case "$asset_url" in
        *.tar.gz) tar -xzf "$archive" -C "$tmpdir" ;;
        *.zip)    unzip -q "$archive" -d "$tmpdir" ;;
        *)        err "Unknown archive format: $asset_url"; exit 1 ;;
    esac

    bin=$(find "$tmpdir" -type f -name "basecamp" | head -n 1)
    if [[ -z "$bin" ]]; then
        err "'basecamp' binary not found in archive."
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$bin" "$INSTALL_DIR/basecamp"
    chmod +x "$INSTALL_DIR/basecamp"

    # Remove Gatekeeper quarantine flag — we just downloaded this, it'll fail on first launch otherwise
    xattr -d com.apple.quarantine "$INSTALL_DIR/basecamp" 2>/dev/null || true

    log "Basecamp CLI installed to $INSTALL_DIR/basecamp"
}

# ── PHASE 4: venv + mcp package ───────────────────────────────────────────────
phase_mcp() {
    local venv_dir="$INSTALL_DIR/.venv"
    log "Creating isolated venv at $venv_dir..."
    "$PY" -m venv "$venv_dir"
    VENV_PY="$venv_dir/bin/python"

    log "Installing 'mcp' into venv..."
    "$VENV_PY" -m pip install --upgrade pip --quiet --disable-pip-version-check
    "$VENV_PY" -m pip install mcp --quiet --disable-pip-version-check
    log "MCP package installed."
}

# ── PHASE 5: Configure Claude Desktop + Basecamp account ──────────────────────
phase_configure() {
    mkdir -p "$INSTALL_DIR"
    cp "$SERVER_SCRIPT_SRC" "$INSTALL_DIR/basecamp_mcp_server.py"

    mkdir -p "$CLAUDE_DIR"

    local server_script="$INSTALL_DIR/basecamp_mcp_server.py"
    local venv_bin
    venv_bin="$(dirname "$VENV_PY")"

    log "Patching Claude Desktop config..."
    CLAUDE_CONFIG="$CLAUDE_CONFIG" \
    VENV_PY="$VENV_PY" \
    SERVER_SCRIPT="$server_script" \
    INSTALL_DIR="$INSTALL_DIR" \
    VENV_BIN="$venv_bin" \
    HOME_ENV="$HOME" \
    "$VENV_PY" - <<'PYEOF'
import json, os, pathlib

cfg_path = pathlib.Path(os.environ["CLAUDE_CONFIG"])
entry = {
    "command": os.environ["VENV_PY"],
    "args": [os.environ["SERVER_SCRIPT"]],
    "env": {
        "HOME": os.environ["HOME_ENV"],
        "PATH": ":".join([
            os.environ["INSTALL_DIR"],
            os.environ["VENV_BIN"],
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
        ]),
    },
}

if cfg_path.exists():
    raw = cfg_path.read_text(encoding="utf-8").lstrip("\ufeff")
    data = json.loads(raw) if raw.strip() else {}
else:
    data = {}

data.setdefault("mcpServers", {})
data["mcpServers"]["basecamp"] = entry

cfg_path.parent.mkdir(parents=True, exist_ok=True)
cfg_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
    log "Claude Desktop config updated: $CLAUDE_CONFIG"

    # Pin the Basecamp account ID. REQUIRED — the CLI does NOT infer it from auth;
    # without it every account-scoped call fails with "--account is required".
    # Artistic Tile is a single-account org (3268280). Multi-account orgs should
    # instead derive this from https://launchpad.37signals.com/authorization.json
    # after login and let the user pick.
    if [[ -x "$INSTALL_DIR/basecamp" ]]; then
        "$INSTALL_DIR/basecamp" config set account_id 3268280 --global >/dev/null 2>&1 \
            && log "Basecamp account ID set (3268280)." \
            || err "Could not set account_id; run: \"$INSTALL_DIR/basecamp\" config set account_id <id> --global"
    fi
}

# ── PHASE 6: Auth (optional final step) ───────────────────────────────────────
phase_auth() {
    log "Launching Basecamp login — a browser window will open (or a URL will print below)."
    # Attach the CLI's stdin to the terminal so any interactive prompts inside
    # `basecamp auth login` work under `bash -c "$(curl ...)"`.
    if [[ -r /dev/tty ]]; then
        "$INSTALL_DIR/basecamp" auth login < /dev/tty || {
            err "'basecamp auth login' failed. You can re-run it manually:"
            err "  \"$INSTALL_DIR/basecamp\" auth login"
        }
    else
        "$INSTALL_DIR/basecamp" auth login || {
            err "'basecamp auth login' failed. You can re-run it manually:"
            err "  \"$INSTALL_DIR/basecamp\" auth login"
        }
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "Installing $APP_NAME on macOS ($ARCH)..."
log ""

phase_python
phase_claude
phase_basecamp
phase_mcp
phase_configure

log ""
log "────────────────────────────────────────────────────────────"
log "Installation complete."
log ""
log "Installed to:    $INSTALL_DIR"
log "Claude config:   $CLAUDE_CONFIG"
log ""
log "Next steps:"
log "  1. Quit Claude Desktop (Cmd+Q) and re-open it."
log "  2. File → Settings → Developer — 'basecamp' should show with a blue dot."
log "  3. Open or create a Project in Claude and paste docs/system-prompt.md"
log "     as the project instructions."
log "────────────────────────────────────────────────────────────"
log ""

if ask_yn "Open Basecamp login now?"; then
    phase_auth
fi
