#!/bin/sh
# Crushcode installer — https://github.com/bibondz/crushcode
# Usage: curl -fsSL https://github.com/bibondz/crushcode/raw/main/install.sh | sh

set -e

REPO="bibondz/crushcode"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="crushcode"

# --- Banner ---
banner() {
    printf '\n'
    printf '  ██████╗██████╗ ███████╗███████╗██╗███████╗███████╗  \n'
    printf ' ██╔════╝██╔══██╗██╔════╝██╔════╝██║██╔════╝██╔════╝  \n'
    printf ' ██║     ██████╔╝█████╗  ███████╗██║███████╗█████╗    \n'
    printf ' ██║     ██╔══██╗██╔══╝  ╚════██║██║╚════██║██╔══╝    \n'
    printf ' ╚██████╗██║  ██║███████╗███████║██║███████║███████╗  \n'
    printf '  ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝╚══════╝╚══════╝  \n'
    printf '              https://github.com/%s\n' "$REPO"
    printf '\n'
}

# --- Helpers ---
die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

info() { printf '  -> %s\n' "$1"; }

detect_arch() {
    _arch="$(uname -m)"
    case "$_arch" in
        x86_64|amd64)    printf 'x86_64'  ;;
        aarch64|arm64)   printf 'aarch64' ;;
        *)               die "Unsupported architecture: $_arch" ;;
    esac
}

detect_os() {
    _os="$(uname -s)"
    case "$_os" in
        Linux)  printf 'linux' ;;
        Darwin) printf 'macos' ;;
        *)      die "Unsupported OS: $_os" ;;
    esac
}

# --- Uninstall ---
do_uninstall() {
    banner
    info "Uninstalling $BINARY_NAME..."
    _found=0
    for _dir in "$INSTALL_DIR" "/usr/local/bin"; do
        _path="$_dir/$BINARY_NAME"
        if [ -f "$_path" ]; then
            rm -f "$_path" || die "Cannot remove $_path (try with sudo)"
            info "Removed $_path"
            _found=1
        fi
    done
    if [ "$_found" = 0 ]; then
        info "$BINARY_NAME not found in $INSTALL_DIR or /usr/local/bin"
    fi
    printf '\nUninstallation complete.\n'
    printf 'You may want to remove the PATH entry from your shell config.\n\n'
    exit 0
}

# --- Parse args ---
VERSION=""
for _arg in "$@"; do
    case "$_arg" in
        --uninstall)  do_uninstall ;;
        --version=*)  VERSION="${_arg#--version=}" ;;
        --version)    ;; # handled by next-arg in curl pipe (skip)
        --help|-h)    banner; printf 'Usage: curl -fsSL .../install.sh | sh [-s -- [--version X.Y.Z] [--uninstall]]\n'; exit 0 ;;
    esac
done

# --- Main install ---
banner

ARCH="$(detect_arch)"
OS="$(detect_os)"
TARGET="$ARCH-$OS"

if [ -n "$VERSION" ]; then
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$BINARY_NAME-$TARGET"
else
    DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$BINARY_NAME-$TARGET"
fi

info "Platform: $TARGET"
info "Installing to $INSTALL_DIR/$BINARY_NAME"

# Create install dir
mkdir -p "$INSTALL_DIR" || die "Cannot create $INSTALL_DIR"

# Download
info "Downloading $DOWNLOAD_URL"
_http_code="$(curl -fsSL -w '%{http_code}' -o "$INSTALL_DIR/$BINARY_NAME" "$DOWNLOAD_URL" 2>/dev/null)" || {
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    die "Download failed. Check your internet connection and the release exists."
}

if [ "$_http_code" != "200" ]; then
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    die "Download failed (HTTP $_http_code). The release for $TARGET may not exist yet."
fi

chmod +x "$INSTALL_DIR/$BINARY_NAME" || die "Cannot make binary executable"

# --- PATH setup ---
add_path() {
    _rc="$1"
    [ -f "$_rc" ] || return 0
    _line='export PATH="$HOME/.local/bin:$PATH"'
    grep -q "$_line" "$_rc" 2>/dev/null && return 0
    printf '\n%s\n' "$_line" >> "$_rc"
    info "Added ~/.local/bin to $(basename "$_rc")"
}

if [ -d "$HOME" ]; then
    add_path "$HOME/.bashrc"
    add_path "$HOME/.zshrc"
    add_path "$HOME/.profile"
fi

# Check if already in PATH
case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        _path_ok=1
        ;;
    *)
        _path_ok=0
        ;;
esac

printf '\n'
info "Installation complete!"
if [ "$_path_ok" = 0 ]; then
    printf '\n  Restart your shell or run:\n'
    printf '    export PATH="$HOME/.local/bin:$PATH"\n\n'
fi
info "Run '$BINARY_NAME --help' to get started."
printf '\n'
