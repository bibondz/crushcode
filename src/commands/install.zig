const std = @import("std");

/// Install script generator for crushcode
pub const Installer = struct {
    const version = "0.1.0";

    /// Generate install script content
    pub fn generateScript() []const u8 {
        return 
        \\#!/bin/sh
        \\# Crushcode Installer
        \\# Version: 0.1.0
        \\
        \\set -e
        \\
        \\# Colors for output
        \\RED='\\033[0;31m'
        \\GREEN='\\033[0;32m'
        \\YELLOW='\\033[1;33m'
        \\NC='\\033[0m' # No Color
        \\
        \\echo "${GREEN}Installing Crushcode v${version}...${NC}"
        \\
        \\# Detect OS
        \\case "$(uname -s)" in
        \\    Linux*)     OS="linux";;
        \\    Darwin*)    OS="macos";;
        \\    CYGWIN*)    OS="windows";;
        \\    MINGW*)     OS="windows";;
        \\    *)          OS="unknown";;
        \\esac
        \\
        \\# Detect architecture
        \\case "$(uname -m)" in
        \\    x86_64)     ARCH="x86_64";;
        \\    aarch64)    ARCH="aarch64";;
        \\    arm64)      ARCH="aarch64";;
        \\    *)          ARCH="unknown";;
        \\esac
        \\
        \\echo "Detected: ${OS}-${ARCH}"
        \\
        \\# Create install directory
        \\INSTALL_DIR="${HOME}/.local/bin"
        \\mkdir -p "${INSTALL_DIR}"
        \\
        \\# Download binary (placeholder - would be real URL in production)
        \\BINARY_NAME="crushcode"
        \\DOWNLOAD_URL="https://github.com/crushcode/crushcode/releases/latest/download/crushcode-${OS}-${ARCH}"
        \\
        \\echo "${YELLOW}Downloading from ${DOWNLOAD_URL}...${NC}"
        \\
        \\# For now, just create a placeholder
        \\echo '#!/bin/sh' > "${INSTALL_DIR}/${BINARY_NAME}"
        \\echo 'echo "Crushcode placeholder - build from source with: git clone && cd crushcode && zig build"' >> "${INSTALL_DIR}/${BINARY_NAME}"
        \\chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
        \\
        \\# Add to PATH if not already there
        \\SHELL_RC="${HOME}/.bashrc"
        \\if [ -f "${HOME}/.zshrc" ]; then
        \\    SHELL_RC="${HOME}/.zshrc"
        \\fi
        \\
        \\if ! grep -q "${INSTALL_DIR}" "${SHELL_RC}" 2>/dev/null; then
        \\    echo '' >> "${SHELL_RC}"
        \\    echo '# Crushcode' >> "${SHELL_RC}"
        \\    echo "export PATH=\\"${INSTALL_DIR}:\\$PATH\\"" >> "${SHELL_RC}"
        \\    echo "${GREEN}Added ${INSTALL_DIR} to PATH in ${SHELL_RC}${NC}"
        \\    echo "${YELLOW}Please run: source ${SHELL_RC}${NC}"
        \\fi
        \\
        \\echo "${GREEN}Installation complete!${NC}"
        \\echo "Run 'crushcode --help' to get started."
        \\
        ;
    }

    /// Generate uninstall script
    pub fn generateUninstallScript() []const u8 {
        return 
        \\#!/bin/sh
        \\# Crushcode Uninstaller
        \\
        \\set -e
        \\
        \\INSTALL_DIR="${HOME}/.local/bin"
        \\BINARY_NAME="crushcode"
        \\
        \\echo "Removing Crushcode..."
        \\rm -f "${INSTALL_DIR}/${BINARY_NAME}"
        \\
        \\# Clean up PATH entry (basic)
        \\echo "Cleaned up install directory."
        \\
        \\echo "Uninstallation complete."
        \\
        ;
    }

    /// Print install instructions
    pub fn printInstallInstructions() void {
        std.debug.print(
            \\Crushcode Installation
            \\
            \\Quick Install:
            \\  curl -sL https://raw.githubusercontent.com/crushcode/crushcode/main/install.sh | sh
            \\
            \\Manual Install:
            \\  1. Clone: git clone https://github.com/crushcode/crushcode.git
            \\  2. Build: cd crushcode && zig build
            \\  3. Install: sudo cp zig-out/bin/crushcode /usr/local/bin/
            \\
            \\Verify: crushcode --version
            \\
        , .{});
    }
};

/// Generate and write install script to file
pub fn writeInstallScript(path: []const u8) !void {
    const content = Installer.generateScript();

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    try file.writeAll(content);

    // Make executable
    try std.os.chmod(path, 0o755);
}

/// Generate and write uninstall script to file
pub fn writeUninstallScript(path: []const u8) !void {
    const content = Installer.generateUninstallScript();

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    try file.writeAll(content);

    try std.os.chmod(path, 0o755);
}

/// Handle install command from CLI
pub fn handleInstall(args: [][]const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--print")) {
        // Just print the install script
        std.debug.print("{s}", .{Installer.generateScript()});
    } else if (args.len > 0 and std.mem.eql(u8, args[0], "--uninstall")) {
        // Print uninstall script
        std.debug.print("{s}", .{Installer.generateUninstallScript()});
    } else {
        // Print instructions
        Installer.printInstallInstructions();
    }
}
