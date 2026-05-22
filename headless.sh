#!/usr/bin/env bash
# =============================================================================
# debian-remaster.sh
# Builds a custom offline Debian ISO with auto-mirror config on first boot.
# Usage: curl -fsSL <raw_url> | sudo bash
#        OR: sudo bash debian-remaster.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — edit these before running if needed
# ─────────────────────────────────────────────────────────────────────────────
DISTRO="bookworm"          # Change to: bullseye, trixie, etc.
ARCH="amd64"
BUILD_DIR="$HOME/debian-custom-iso"
ISO_NAME="debian-custom-$(date +%Y%m%d).iso"

# Packages to bake into the ISO (add/remove as needed)
PACKAGES=(
    curl
    wget
    git
    sudo
    openssh-server
    bash-completion
    ufw
    ca-certificates
    gnupg
    netselect-apt     # used for auto-mirror selection on first boot
)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

check_deps() {
    info "Checking dependencies..."
    local missing=()
    for cmd in live-build lb xorriso; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing tools: ${missing[*]}"
        apt-get update -qq
        apt-get install -y live-build xorriso
    fi
    success "All dependencies present."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Prepare build directory
# ─────────────────────────────────────────────────────────────────────────────
prepare_dirs() {
    info "Preparing build directory at $BUILD_DIR ..."

    if [[ -d "$BUILD_DIR" ]]; then
        warn "Build directory already exists. Cleaning previous build..."
        cd "$BUILD_DIR" && lb clean --purge 2>/dev/null || true
        rm -rf "$BUILD_DIR"
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    success "Build directory ready."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Configure live-build
# ─────────────────────────────────────────────────────────────────────────────
configure_lb() {
    info "Configuring live-build (distro=$DISTRO, arch=$ARCH)..."
    cd "$BUILD_DIR"

    lb config \
        --mode debian \
        --distribution "$DISTRO" \
        --architectures "$ARCH" \
        --archive-areas "main contrib non-free non-free-firmware" \
        --debian-installer live \
        --debian-installer-gui false \
        --apt-indices false \
        --bootappend-live "boot=live components quiet splash" \
        --iso-volume "Debian-Custom-$(date +%Y%m%d)" \
        --image-name "$ISO_NAME"

    success "live-build configured."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Write package list
# ─────────────────────────────────────────────────────────────────────────────
write_packages() {
    info "Writing package list..."
    mkdir -p "$BUILD_DIR/config/package-lists"

    local pkg_file="$BUILD_DIR/config/package-lists/custom.list.chroot"
    printf '%s\n' "${PACKAGES[@]}" > "$pkg_file"

    success "Package list written: $pkg_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Write first-boot auto-mirror hook
# ─────────────────────────────────────────────────────────────────────────────
write_mirror_hook() {
    info "Writing auto-mirror hook..."
    mkdir -p "$BUILD_DIR/config/hooks/normal"

    cat > "$BUILD_DIR/config/hooks/normal/0010-auto-mirror.hook.chroot" << 'HOOK'
#!/bin/bash
# This hook installs a first-boot script that auto-selects the fastest
# Debian mirror using netselect-apt, then disables itself.

cat > /usr/local/bin/auto-configure-mirror << 'INNERSCRIPT'
#!/bin/bash
FLAG="/etc/apt/.mirror-configured"
[[ -f "$FLAG" ]] && exit 0

echo "[auto-mirror] Detecting fastest Debian mirror..."

# Fallback: use the official CDN-backed redirector (works without netselect-apt)
SOURCES_LIST="/etc/apt/sources.list"
DISTRO=$(lsb_release -cs 2>/dev/null || echo "bookworm")

if command -v netselect-apt &>/dev/null; then
    # Pick the fastest mirror automatically
    netselect-apt -n -o "$SOURCES_LIST" "$DISTRO" 2>/dev/null \
        && echo "[auto-mirror] Mirror selected via netselect-apt." \
        || true
fi

# Ensure the CDN fallback is always present if sources.list is empty/broken
if ! grep -q "^deb " "$SOURCES_LIST" 2>/dev/null; then
    echo "[auto-mirror] Falling back to deb.debian.org (CDN-backed, auto-routes by GeoIP)..."
    cat > "$SOURCES_LIST" << EOF
deb http://deb.debian.org/debian $DISTRO main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $DISTRO-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DISTRO-security main contrib non-free non-free-firmware
EOF
fi

apt-get update -qq
touch "$FLAG"
echo "[auto-mirror] Done. Mirror configured."
INNERSCRIPT

chmod +x /usr/local/bin/auto-configure-mirror

# Wire it into rc.local so it runs on first boot
cat > /etc/rc.local << 'RC'
#!/bin/bash
/usr/local/bin/auto-configure-mirror
exit 0
RC

chmod +x /etc/rc.local

# Also enable rc-local service (needed on systemd Debian)
systemctl enable rc-local 2>/dev/null || true
HOOK

    chmod +x "$BUILD_DIR/config/hooks/normal/0010-auto-mirror.hook.chroot"
    success "Auto-mirror hook written."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Optional: preseed for fully automated installs
# ─────────────────────────────────────────────────────────────────────────────
# write_preseed() {
#     info "Writing basic preseed..."
#     mkdir -p "$BUILD_DIR/config/preseed"

#     cat > "$BUILD_DIR/config/preseed/custom.cfg" << 'PRESEED'
# # Skip locale/keyboard questions
# d-i debian-installer/locale string en_US.UTF-8
# d-i keyboard-configuration/xkb-keymap select us

# # Network — use DHCP
# d-i netcfg/choose_interface select auto
# d-i netcfg/get_hostname string debian
# d-i netcfg/get_domain string localdomain

# # Skip the mirror step entirely (packages are in the ISO)
# d-i mirror/country string manual
# d-i mirror/http/hostname string deb.debian.org
# d-i mirror/http/directory string /debian
# d-i mirror/http/proxy string

# # Clock
# d-i clock-setup/utc boolean true
# d-i time/zone string Asia/Karachi

# # No root password — use sudo user instead
# # d-i passwd/root-login boolean false
# # d-i passwd/user-fullname string User
# # d-i passwd/username string user
# # d-i passwd/user-password password changeme
# # d-i passwd/user-password-again password changeme
# # d-i passwd/user-default-groups string sudo

# # Partitioning — guided, use entire disk
# d-i partman-auto/method string regular
# d-i partman-auto/choose_recipe select atomic
# d-i partman/confirm_write_new_label boolean true
# d-i partman/confirm boolean true
# d-i partman/confirm_nooverwrite boolean true

# # Install GRUB to MBR
# d-i grub-installer/only_debian boolean true
# d-i grub-installer/bootdev string default

# # Finish
# d-i finish-install/reboot_in_progress note
# PRESEED

#     success "Preseed written (edit $BUILD_DIR/config/preseed/custom.cfg to customize)."
# }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Build the ISO
# ─────────────────────────────────────────────────────────────────────────────
build_iso() {
    info "Starting ISO build — this will take a while..."
    info "Logs: $BUILD_DIR/build.log"
    cd "$BUILD_DIR"

    lb build 2>&1 | tee "$BUILD_DIR/build.log"

    # Find the output ISO
    local iso_path
    iso_path=$(find "$BUILD_DIR" -maxdepth 1 -name "*.iso" | head -n1)

    if [[ -z "$iso_path" ]]; then
        die "Build finished but no ISO found. Check $BUILD_DIR/build.log for errors."
    fi

    success "ISO built successfully!"
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  ISO location:${RESET} $iso_path"
    echo -e "${BOLD}  Size:${RESET}         $(du -sh "$iso_path" | cut -f1)"
    echo ""
    echo -e "${BOLD}  To test in VirtualBox:${RESET}"
    echo -e "    Attach '$iso_path' as a virtual optical drive and boot."
    echo ""
    echo -e "${BOLD}  To write to USB:${RESET}"
    echo -e "    sudo dd if=\"$iso_path\" of=/dev/sdX bs=4M status=progress oflag=sync"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║      Debian Custom ISO Builder               ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo ""

    require_root
    check_deps
    prepare_dirs
    configure_lb
    write_packages
    write_mirror_hook
    write_preseed
    build_iso
}

main "$@"