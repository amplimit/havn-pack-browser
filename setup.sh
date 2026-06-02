#!/usr/bin/env bash
#
# havn-pack-browser — host installer
#
# Installs Chromium + Node.js + @playwright/cli into /opt/havn/ once on the
# host. All havn agents on the host share the install — no per-agent
# download. Idempotent: re-running upgrades in place.
#
# Tested on Debian 12 / Ubuntu 24.04. Other distros: read the comments in
# install_chromium / install_node and adapt the package commands.

set -euo pipefail

PREFIX="${HAVN_PACK_PREFIX:-/opt/havn}"
NODE_VERSION="${HAVN_NODE_VERSION:-22}"   # LTS-current
PLAYWRIGHT_CLI_VERSION="${HAVN_PLAYWRIGHT_CLI_VERSION:-latest}"

log() { printf '\033[1;36m[pack]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[pack]\033[0m %s\n' "$*" >&2; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "this script writes under $PREFIX — re-run with sudo, or set HAVN_PACK_PREFIX to a writable path"
        exit 1
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    elif command -v brew >/dev/null 2>&1; then
        echo brew
    else
        echo unknown
    fi
}

install_chromium() {
    local pm
    pm="$(detect_pkg_manager)"
    case "$pm" in
        apt)
            log "installing Chromium via apt"
            apt-get update -qq
            # chromium on Debian; chromium-browser on Ubuntu pre-22; ubuntu 24+ uses snap-shim
            # (we want the real .deb; on snap-default ubuntu, install chromium from t64 if needed).
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                chromium chromium-driver \
                libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxkbcommon0 \
                libxcomposite1 libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 \
                libcairo2 libasound2t64 fonts-liberation \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium-browser
            ;;
        dnf)
            log "installing Chromium via dnf"
            dnf install -y chromium chromium-headless
            ;;
        pacman)
            log "installing Chromium via pacman"
            pacman -S --noconfirm --needed chromium
            ;;
        brew)
            err "brew detected — macOS isn't a tested target. Install Chromium yourself, then re-run with HAVN_PACK_SKIP_CHROMIUM=1"
            exit 2
            ;;
        *)
            err "unknown package manager. Install Chromium manually, then re-run with HAVN_PACK_SKIP_CHROMIUM=1"
            exit 2
            ;;
    esac

    # Symlink whichever name we got into a stable path.
    mkdir -p "$PREFIX/chromium"
    for cand in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome; do
        if [ -x "$cand" ]; then
            ln -sf "$cand" "$PREFIX/chromium/chromium"
            log "linked $cand → $PREFIX/chromium/chromium"
            return
        fi
    done
    err "Chromium binary not found after install"
    exit 3
}

install_node() {
    if command -v node >/dev/null 2>&1; then
        local installed_major
        installed_major=$(node -v | sed 's/^v//' | cut -d. -f1)
        if [ "$installed_major" -ge "$NODE_VERSION" ]; then
            log "node $(node -v) already on PATH (≥ $NODE_VERSION) — skipping"
            mkdir -p "$PREFIX/node/bin"
            ln -sf "$(command -v node)" "$PREFIX/node/bin/node"
            ln -sf "$(command -v npm)"  "$PREFIX/node/bin/npm"
            ln -sf "$(command -v npx)"  "$PREFIX/node/bin/npx"
            return
        fi
        log "node $(node -v) is older than $NODE_VERSION; installing newer in $PREFIX/node"
    else
        log "node not on PATH; installing in $PREFIX/node"
    fi

    # Tarball install — keeps havn-pack-browser self-contained, no nodesource repo gunk.
    local arch tarball url tmp
    arch="$(uname -m)"
    case "$arch" in
        x86_64) arch=x64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) err "unsupported arch: $arch"; exit 4 ;;
    esac
    # Resolve "current LTS in series N" — request the well-known latest-vN url
    tarball="node-latest-linux-$arch.tar.xz"
    url="https://nodejs.org/dist/latest-v${NODE_VERSION}.x/$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_VERSION}.x/" \
        | grep -oE "node-v[0-9.]+-linux-${arch}.tar.xz" | head -1)"
    if [ -z "${url%*/}" ]; then
        err "couldn't resolve Node tarball URL — check your network or set HAVN_NODE_VERSION"
        exit 4
    fi
    tmp="$(mktemp -d)"
    log "fetching $url"
    curl -fsSL "$url" -o "$tmp/node.tar.xz"
    rm -rf "$PREFIX/node"
    mkdir -p "$PREFIX/node"
    tar -xJf "$tmp/node.tar.xz" -C "$PREFIX/node" --strip-components=1
    rm -rf "$tmp"
    log "node $("$PREFIX/node/bin/node" -v) installed at $PREFIX/node"
}

install_playwright_cli() {
    log "installing @playwright/cli ($PLAYWRIGHT_CLI_VERSION) into $PREFIX/playwright-cli"
    mkdir -p "$PREFIX/playwright-cli"
    cd "$PREFIX/playwright-cli"
    cat > package.json <<JSON
{
  "name": "havn-pack-browser-runtime",
  "private": true,
  "dependencies": {
    "@playwright/cli": "$PLAYWRIGHT_CLI_VERSION"
  }
}
JSON
    "$PREFIX/node/bin/npm" install --omit=dev --no-fund --no-audit --silent

    # Stable launcher. Resolves to @playwright/cli's actual entry
    # (playwright-cli.js at the package root, NOT dist/cli.js — the package
    # ships the script directly). Pins PLAYWRIGHT_BROWSERS_PATH next to the
    # install so an updated chromium download lands beside the cli, not in
    # the calling user's $HOME cache.
    cat > "$PREFIX/playwright-cli/playwright-cli" <<SH
#!/usr/bin/env bash
HERE="\$(cd "\$(dirname "\$(readlink -f "\$0")")" && pwd)"
export PLAYWRIGHT_BROWSERS_PATH="\${PLAYWRIGHT_BROWSERS_PATH:-\$HERE/.browsers}"
exec "$PREFIX/node/bin/node" "\$HERE/node_modules/@playwright/cli/playwright-cli.js" "\$@"
SH
    chmod +x "$PREFIX/playwright-cli/playwright-cli"

    log "downloading Playwright's bundled chromium (~115 MB)"
    "$PREFIX/playwright-cli/playwright-cli" install-browser chromium >/dev/null
    log "chromium-headless-shell installed under $PREFIX/playwright-cli/.browsers"

    # Expose on system PATH so agents inside namespaces see it without
    # extra bind-mount fuss (the namespace inherits the host's PATH-bound
    # files via the standard /usr bind-mount).
    ln -sf "$PREFIX/playwright-cli/playwright-cli" /usr/local/bin/playwright-cli
    log "symlinked $PREFIX/playwright-cli/playwright-cli → /usr/local/bin/playwright-cli"
}

verify() {
    log "verifying"
    local node_v cli_help
    node_v="$("$PREFIX/node/bin/node" -v)"
    cli_help="$("$PREFIX/playwright-cli/playwright-cli" --help 2>&1 | head -1 || true)"
    log "  node:           $node_v"
    log "  playwright-cli: ${cli_help:-(no output — check install)}"
    log "  bundled chromium: $(ls -d "$PREFIX/playwright-cli/.browsers"/chromium* 2>/dev/null | head -1 || echo '?')"

    cat <<NEXT

Done. To enable browser for an agent:

  mkdir -p /var/lib/havn/agents/<agent-id>/workspace/skills/browser
  cp $(pwd)/SKILL.md /var/lib/havn/agents/<agent-id>/workspace/skills/browser/SKILL.md
  havn agent stop <agent-id> && havn agent start <agent-id>

Add $PREFIX/playwright-cli to PATH (or symlink the launcher into /usr/local/bin):

  ln -sf $PREFIX/playwright-cli/playwright-cli /usr/local/bin/playwright-cli

Then in a webchat, ask the agent to use a browser for a page web_fetch can't
read. The agent's LLM picks up the SKILL.md from its workspace at session
start and knows what to do.
NEXT
}

main() {
    require_root
    log "havn-pack-browser setup → $PREFIX"
    install_node
    # @playwright/cli's `install-browser chromium` step (run inside
    # install_playwright_cli) downloads Playwright's vendored
    # chromium-headless-shell — that's what the CLI actually drives.
    # No system Chromium needed; pulling apt's chromium on Ubuntu 24+
    # gets a snap-shim that doesn't work in agent namespaces anyway.
    install_playwright_cli
    verify
}

main "$@"
