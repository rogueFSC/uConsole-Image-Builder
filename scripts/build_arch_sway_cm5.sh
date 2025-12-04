#!/bin/bash
#
# build_arch_sway_cm5.sh - Build Arch Linux ARM + Sway image for uConsole CM5
#
# This script creates a bootable SD card image with:
# - Arch Linux ARM base system
# - PeterCxy's uConsole CM5 kernel (linux-clockworkpi-git)
# - Sway window manager configured for uConsole
# - All hardware support (display, WiFi, audio, backlight)
#
# Usage:
#   sudo ./build_arch_sway_cm5.sh /dev/sdX        # Write directly to SD card
#   sudo ./build_arch_sway_cm5.sh ./output.img    # Create image file
#
# Requirements:
#   - Linux host (x86_64 or aarch64)
#   - Root privileges
#   - ~8GB free disk space
#   - Internet connection
#   - qemu-user-static (for x86_64 hosts)
#
# Based on PeterCxy's work: https://typeblog.net/61092/

set -euo pipefail

# Configuration
ARCH_TARBALL_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ARCH_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"
IMAGE_SIZE="8G"
BOOT_SIZE="512M"
DEFAULT_USER="uconsole"
DEFAULT_PASS="uconsole"
HOSTNAME="uconsole"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Cleanup function
cleanup() {
    log_info "Cleaning up..."

    # Unmount in reverse order
    for mount in proc sys dev/pts dev boot; do
        if mountpoint -q "${MOUNT_POINT}/${mount}" 2>/dev/null; then
            umount -lf "${MOUNT_POINT}/${mount}" 2>/dev/null || true
        fi
    done

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        umount -lf "${MOUNT_POINT}" 2>/dev/null || true
    fi

    if [ -n "${LOOP_DEVICE:-}" ] && [ -e "${LOOP_DEVICE}" ]; then
        losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
    fi

    if [ -d "${MOUNT_POINT:-}" ]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Check requirements
check_requirements() {
    log_info "Checking requirements..."

    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi

    local required_cmds="wget parted mkfs.vfat mkfs.ext4 losetup arch-chroot"
    for cmd in $required_cmds; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    # Check for qemu-user-static on x86_64
    if [ "$(uname -m)" = "x86_64" ]; then
        if [ ! -f /usr/bin/qemu-aarch64-static ] && [ ! -f /usr/bin/qemu-aarch64 ]; then
            log_warn "qemu-user-static not found - required for x86_64 hosts"
            log_info "Install with: apt install qemu-user-static binfmt-support"
            exit 1
        fi
    fi

    log_success "All requirements met"
}

# Download Arch Linux ARM tarball
download_rootfs() {
    log_info "Downloading Arch Linux ARM rootfs..."

    if [ -f "${ARCH_TARBALL}" ]; then
        log_info "Using existing tarball: ${ARCH_TARBALL}"
    else
        wget -q --show-progress "${ARCH_TARBALL_URL}" -O "${ARCH_TARBALL}"
    fi

    log_success "Rootfs ready"
}

# Setup target device/image
setup_target() {
    local target="$1"

    if [ -b "$target" ]; then
        # Block device (SD card)
        log_info "Target is block device: $target"
        log_warn "ALL DATA ON $target WILL BE DESTROYED!"
        read -p "Continue? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_error "Aborted by user"
            exit 1
        fi

        # Unmount any existing partitions
        for part in ${target}*; do
            umount "$part" 2>/dev/null || true
        done

        LOOP_DEVICE=""
        DEVICE="$target"
    else
        # Image file
        log_info "Creating image file: $target (${IMAGE_SIZE})"

        # Create sparse image
        truncate -s "${IMAGE_SIZE}" "$target"

        LOOP_DEVICE=$(losetup -f)
        losetup -P "${LOOP_DEVICE}" "$target"
        DEVICE="${LOOP_DEVICE}"

        log_info "Loop device: ${LOOP_DEVICE}"
    fi
}

# Partition the device
partition_device() {
    log_info "Partitioning device..."

    # Create GPT partition table with boot and root partitions
    parted -s "${DEVICE}" mklabel msdos
    parted -s "${DEVICE}" mkpart primary fat32 1MiB "${BOOT_SIZE}"
    parted -s "${DEVICE}" set 1 boot on
    parted -s "${DEVICE}" mkpart primary ext4 "${BOOT_SIZE}" 100%

    # Wait for partition devices to appear
    sleep 2
    partprobe "${DEVICE}" 2>/dev/null || true
    sleep 1

    # Determine partition names
    if [[ "${DEVICE}" == *"nvme"* ]] || [[ "${DEVICE}" == *"loop"* ]]; then
        BOOT_PART="${DEVICE}p1"
        ROOT_PART="${DEVICE}p2"
    else
        BOOT_PART="${DEVICE}1"
        ROOT_PART="${DEVICE}2"
    fi

    log_info "Boot partition: ${BOOT_PART}"
    log_info "Root partition: ${ROOT_PART}"

    # Format partitions
    log_info "Formatting partitions..."
    mkfs.vfat -F32 "${BOOT_PART}"
    mkfs.ext4 -F "${ROOT_PART}"

    log_success "Partitioning complete"
}

# Mount partitions
mount_partitions() {
    log_info "Mounting partitions..."

    MOUNT_POINT=$(mktemp -d)

    mount "${ROOT_PART}" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/boot"
    mount "${BOOT_PART}" "${MOUNT_POINT}/boot"

    log_success "Mounted at ${MOUNT_POINT}"
}

# Extract rootfs
extract_rootfs() {
    log_info "Extracting Arch Linux ARM rootfs (this takes a few minutes)..."

    bsdtar -xpf "${ARCH_TARBALL}" -C "${MOUNT_POINT}"

    log_success "Rootfs extracted"
}

# Setup chroot environment
setup_chroot() {
    log_info "Setting up chroot environment..."

    # Bind mounts for chroot
    mount --bind /dev "${MOUNT_POINT}/dev"
    mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
    mount --bind /proc "${MOUNT_POINT}/proc"
    mount --bind /sys "${MOUNT_POINT}/sys"

    # Copy QEMU if on x86_64
    if [ "$(uname -m)" = "x86_64" ]; then
        if [ -f /usr/bin/qemu-aarch64-static ]; then
            cp /usr/bin/qemu-aarch64-static "${MOUNT_POINT}/usr/bin/"
        fi
    fi

    # Setup DNS
    cp /etc/resolv.conf "${MOUNT_POINT}/etc/resolv.conf"

    log_success "Chroot environment ready"
}

# Configure the system inside chroot
configure_system() {
    log_info "Configuring system..."

    # Create configuration script to run in chroot
    cat > "${MOUNT_POINT}/tmp/setup.sh" << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

echo "==> Initializing pacman keyring..."
pacman-key --init
pacman-key --populate archlinuxarm

echo "==> Adding PeterCxy's repository..."
cat >> /etc/pacman.conf << 'EOF'

# uConsole CM5 kernel and packages
[petercxy]
SigLevel = Optional
Server = https://s3-cdn.angry.im/alarm-repo/$arch
EOF

echo "==> Updating system and installing kernel..."
pacman -Syu --noconfirm
pacman -S --noconfirm linux-clockworkpi-git linux-clockworkpi-git-headers

echo "==> Installing WiFi fix..."
pacman -S --noconfirm wpa_supplicant-raspberrypi-git || pacman -S --noconfirm wpa_supplicant

echo "==> Installing Sway and desktop packages..."
pacman -S --noconfirm \
    sway swaylock swayidle swaybg waybar \
    foot wofi mako grim slurp wl-clipboard \
    xdg-desktop-portal-wlr \
    ttf-dejavu noto-fonts ttf-font-awesome \
    pipewire pipewire-pulse wireplumber \
    light brightnessctl \
    networkmanager network-manager-applet \
    bluez bluez-utils \
    polkit \
    sudo vim nano htop neofetch \
    git base-devel \
    firefox

echo "==> Installing Raspberry Pi utilities..."
pacman -S --noconfirm raspberrypi-utils || true

echo "==> Enabling services..."
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable sshd

echo "==> Creating user..."
useradd -m -G wheel,video,audio,input -s /bin/bash uconsole || true
echo "uconsole:uconsole" | chpasswd

echo "==> Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
echo "uconsole ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/uconsole

echo "==> Setting hostname..."
echo "uconsole" > /etc/hostname
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   uconsole.localdomain uconsole
EOF

echo "==> Setting locale..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "==> Setting timezone..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

echo "==> Cleaning up..."
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "==> System configuration complete!"
CHROOT_SCRIPT

    chmod +x "${MOUNT_POINT}/tmp/setup.sh"

    # Run the setup script in chroot
    arch-chroot "${MOUNT_POINT}" /tmp/setup.sh

    rm "${MOUNT_POINT}/tmp/setup.sh"

    log_success "System configured"
}

# Create boot configuration
create_boot_config() {
    log_info "Creating boot configuration..."

    # config.txt for Raspberry Pi bootloader
    cat > "${MOUNT_POINT}/boot/config.txt" << 'EOF'
# uConsole CM5 Boot Configuration
# Generated by build_arch_sway_cm5.sh

[all]
arm_64bit=1
disable_overscan=1
dtparam=audio=on
auto_initramfs=1
max_framebuffers=2

# Audio remapping for uConsole speaker
dtoverlay=audremap,pins_12_13
dtoverlay=dwc2,dr_mode=host

# Antenna configuration
dtparam=ant2

# SPI for display
dtparam=spi=on

[pi4]
# CM4 fallback (if kernel supports both)
dtoverlay=clockworkpi-uconsole
dtoverlay=vc4-kms-v3d-pi4,cma-384
dtparam=pciex1=off
enable_uart=1

[pi5]
# CM5 primary configuration
dtoverlay=clockworkpi-uconsole-cm5
dtoverlay=vc4-kms-v3d-pi5,cma-384
dtparam=pciex1=off
enable_uart=1

# Kernel and initramfs
kernel=vmlinuz-linux-clockworkpi-git
initramfs initramfs-linux-clockworkpi-git.img followkernel
EOF

    # cmdline.txt
    ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
    cat > "${MOUNT_POINT}/boot/cmdline.txt" << EOF
root=UUID=${ROOT_UUID} rw rootwait console=tty1 loglevel=4
EOF

    log_success "Boot configuration created"
}

# Create Sway configuration
create_sway_config() {
    log_info "Creating Sway configuration for uConsole..."

    local sway_dir="${MOUNT_POINT}/home/uconsole/.config/sway"
    mkdir -p "$sway_dir"

    cat > "${sway_dir}/config" << 'EOF'
# Sway configuration for ClockworkPi uConsole
# Based on PeterCxy's optimizations

# Use Alt as modifier (uConsole has no Super key)
set $mod Mod1

# Terminal
set $term foot

# Application launcher
set $menu wofi --show drun

# Display configuration for uConsole 5" screen
output DSI-2 scale 1.2

# Trackball scroll emulation (hold middle button + move to scroll)
input type:pointer {
    scroll_button button3
    scroll_method on_button_down
    natural_scroll enabled
}

# Keyboard configuration
input type:keyboard {
    xkb_layout us
}

# Key bindings
bindsym $mod+Return exec $term
bindsym $mod+d exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit sway?' -B 'Yes' 'swaymsg exit'

# Focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right

# Move windows
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

# Workspaces
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5

bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5

# Layout
bindsym $mod+b splith
bindsym $mod+v splitv
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle

# Scratchpad
bindsym $mod+Shift+minus move scratchpad
bindsym $mod+minus scratchpad show

# Resize mode
mode "resize" {
    bindsym h resize shrink width 10px
    bindsym j resize grow height 10px
    bindsym k resize shrink height 10px
    bindsym l resize grow width 10px
    bindsym Left resize shrink width 10px
    bindsym Down resize grow height 10px
    bindsym Up resize shrink height 10px
    bindsym Right resize grow width 10px
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# Backlight control (uConsole uses discrete steps)
bindsym --locked XF86MonBrightnessUp exec light -S "$(light -G | awk '{ print (int($1 / 10) + 2) * 10 }')"
bindsym --locked XF86MonBrightnessDown exec light -S "$(light -G | awk '{ v = (int($1 / 10) - 2) * 10; print (v < 20 ? 20 : v) }')"

# Volume control
bindsym --locked XF86AudioRaiseVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindsym --locked XF86AudioLowerVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym --locked XF86AudioMute exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle

# Screenshot
bindsym Print exec grim -g "$(slurp)" - | wl-copy

# Lock screen
bindsym $mod+Ctrl+l exec swaylock -f -c 000000

# Idle configuration with uConsole power management
exec swayidle -w \
    timeout 300 'swaylock -f -c 000000' \
    timeout 600 'swaymsg "output * dpms off"' \
    resume 'swaymsg "output * dpms on"' \
    before-sleep 'swaylock -f -c 000000'

# Status bar
bar {
    position top
    status_command waybar
    colors {
        statusline #ffffff
        background #323232
        inactive_workspace #32323200 #32323200 #5c5c5c
    }
}

# Autostart
exec mako
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 || true

# Default styling
default_border pixel 2
gaps inner 5
gaps outer 5

include /etc/sway/config.d/*
EOF

    # Fix ownership
    arch-chroot "${MOUNT_POINT}" chown -R uconsole:uconsole /home/uconsole/.config

    log_success "Sway configuration created"
}

# Create waybar configuration
create_waybar_config() {
    log_info "Creating Waybar configuration..."

    local waybar_dir="${MOUNT_POINT}/home/uconsole/.config/waybar"
    mkdir -p "$waybar_dir"

    cat > "${waybar_dir}/config" << 'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 24,
    "modules-left": ["sway/workspaces", "sway/mode"],
    "modules-center": ["sway/window"],
    "modules-right": ["pulseaudio", "network", "battery", "clock"],

    "sway/workspaces": {
        "disable-scroll": true
    },

    "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%Y-%m-%d}"
    },

    "battery": {
        "format": "{icon} {capacity}%",
        "format-icons": ["", "", "", "", ""],
        "format-charging": " {capacity}%"
    },

    "network": {
        "format-wifi": " {signalStrength}%",
        "format-ethernet": "",
        "format-disconnected": ""
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "",
        "format-icons": {
            "default": ["", "", ""]
        },
        "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
    }
}
EOF

    cat > "${waybar_dir}/style.css" << 'EOF'
* {
    font-family: "DejaVu Sans", "Font Awesome 6 Free";
    font-size: 12px;
}

window#waybar {
    background-color: rgba(43, 48, 59, 0.9);
    color: #ffffff;
}

#workspaces button {
    padding: 0 5px;
    color: #ffffff;
}

#workspaces button.focused {
    background-color: #64727D;
}

#clock, #battery, #network, #pulseaudio {
    padding: 0 10px;
}

#battery.charging {
    color: #26A65B;
}

#battery.warning:not(.charging) {
    color: #f53c3c;
}
EOF

    arch-chroot "${MOUNT_POINT}" chown -R uconsole:uconsole /home/uconsole/.config

    log_success "Waybar configuration created"
}

# Create foot terminal configuration
create_foot_config() {
    log_info "Creating Foot terminal configuration..."

    local foot_dir="${MOUNT_POINT}/home/uconsole/.config/foot"
    mkdir -p "$foot_dir"

    cat > "${foot_dir}/foot.ini" << 'EOF'
[main]
font=monospace:size=10
dpi-aware=yes

[colors]
background=282828
foreground=ebdbb2

[cursor]
color=282828 ebdbb2
EOF

    arch-chroot "${MOUNT_POINT}" chown -R uconsole:uconsole /home/uconsole/.config

    log_success "Foot configuration created"
}

# Create auto-login for Sway
create_autologin() {
    log_info "Configuring auto-login to Sway..."

    # Create .bash_profile to start Sway on login
    cat > "${MOUNT_POINT}/home/uconsole/.bash_profile" << 'EOF'
# Start Sway on tty1
if [ -z "$DISPLAY" ] && [ "$XDG_VTNR" = 1 ]; then
    exec sway
fi
EOF

    # Enable auto-login on tty1
    mkdir -p "${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d"
    cat > "${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin uconsole %I $TERM
EOF

    arch-chroot "${MOUNT_POINT}" chown uconsole:uconsole /home/uconsole/.bash_profile

    log_success "Auto-login configured"
}

# Main function
main() {
    echo ""
    echo "=============================================="
    echo "  Arch Linux ARM + Sway for uConsole CM5"
    echo "=============================================="
    echo ""

    if [ $# -lt 1 ]; then
        echo "Usage: $0 <device|image>"
        echo ""
        echo "Examples:"
        echo "  $0 /dev/sdb           # Write to SD card"
        echo "  $0 ./uconsole-cm5.img # Create image file"
        echo ""
        exit 1
    fi

    local target="$1"

    check_requirements
    download_rootfs
    setup_target "$target"
    partition_device
    mount_partitions
    extract_rootfs
    setup_chroot
    configure_system
    create_boot_config
    create_sway_config
    create_waybar_config
    create_foot_config
    create_autologin

    echo ""
    log_success "=============================================="
    log_success "  Build complete!"
    log_success "=============================================="
    echo ""
    echo "Default credentials:"
    echo "  Username: uconsole"
    echo "  Password: uconsole"
    echo ""
    echo "Sway will start automatically on boot."
    echo "Key bindings use Alt as the modifier key."
    echo ""
    echo "First boot tips:"
    echo "  - Connect to WiFi: nmtui"
    echo "  - Update system: sudo pacman -Syu"
    echo ""

    if [ -n "${LOOP_DEVICE:-}" ]; then
        echo "Image created: $target"
        echo "Write to SD card with:"
        echo "  sudo dd if=$target of=/dev/sdX bs=4M status=progress"
    else
        echo "SD card is ready. Insert into uConsole and boot!"
    fi
    echo ""
}

main "$@"
