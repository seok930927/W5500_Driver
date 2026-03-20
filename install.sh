#!/bin/bash
# Target: Raspberry Pi Zero 2W (ARMv8, Raspberry Pi OS)
# This script builds and installs the W5500 optimized driver
# replacing the stock w5100/w5100-spi kernel modules.
set -e

WIZNET_DIR="/lib/modules/$(uname -r)/kernel/drivers/net/ethernet/wiznet"
REPO_URL="https://github.com/seok930927/W5500_Driver"
TMP_DIR=$(mktemp -d -p "$HOME")

# Handle -Remove flag
if [[ "$1" == "-Remove" || "$1" == "--remove" ]]; then
    echo "=== W5500 Driver Removal ==="
    echo "Kernel : $(uname -r)"
    echo ""

    if [ ! -f "$WIZNET_DIR/w5100.ko.xz.bak" ] && [ ! -f "$WIZNET_DIR/w5100-spi.ko.xz.bak" ]; then
        echo "ERROR: No backup files found. Cannot revert."
        exit 1
    fi

    echo "Restoring original drivers..."
    [ -f "$WIZNET_DIR/w5100.ko.xz.bak"     ] && sudo mv "$WIZNET_DIR/w5100.ko.xz.bak"     "$WIZNET_DIR/w5100.ko.xz"     && echo "  Restored: w5100.ko.xz"
    [ -f "$WIZNET_DIR/w5100-spi.ko.xz.bak" ] && sudo mv "$WIZNET_DIR/w5100-spi.ko.xz.bak" "$WIZNET_DIR/w5100-spi.ko.xz" && echo "  Restored: w5100-spi.ko.xz"
    sudo rm -f "$WIZNET_DIR/w5100.ko" "$WIZNET_DIR/w5100_spi.ko"
    sudo depmod -a

    echo ""
    echo "=== Removal complete ==="
    read -p "Reboot now? (y/N): " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] && sudo reboot
    exit 0
fi

# Cleanup TMP_DIR on exit or failure
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== W5500 Driver Build & Install ==="
echo "Target : Raspberry Pi Zero 2W"
echo "Kernel : $(uname -r)"
echo ""

# Check if driver is already installed
if [ -f "$WIZNET_DIR/w5100.ko.xz.bak" ] || [ -f "$WIZNET_DIR/w5100-spi.ko.xz.bak" ]; then
    echo "[!] Previously installed driver detected."
    echo "    Backup files exist:"
    [ -f "$WIZNET_DIR/w5100.ko.xz.bak"     ] && echo "      - w5100.ko.xz.bak"
    [ -f "$WIZNET_DIR/w5100-spi.ko.xz.bak" ] && echo "      - w5100-spi.ko.xz.bak"
    read -p "    Overwrite and continue? (y/N): " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Aborted."; exit 0; }
fi

# Check build dependencies
echo "[1/5] Checking build dependencies..."
for pkg in git make gcc; do
    if ! command -v "$pkg" &>/dev/null; then
        echo "  Installing: $pkg"
        sudo apt-get install -y "$pkg"
    fi
done

# Install kernel headers if missing
if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    echo "  Installing kernel headers..."
    # Raspberry Pi OS uses raspberrypi-kernel-headers
    if apt-cache show raspberrypi-kernel-headers &>/dev/null; then
        sudo apt-get install -y raspberrypi-kernel-headers
    else
        sudo apt-get install -y "linux-headers-$(uname -r)"
    fi
fi

# Clone source
echo "[2/5] Downloading source..."
git clone "$REPO_URL" "$TMP_DIR/W5500_Driver"

# Build
echo "[3/5] Building..."
cd "$TMP_DIR/W5500_Driver/source"
make DEBUG=0

# Verify build output (make can exit 0 even if .ko was not produced)
if [ ! -f build/w5100.ko ] || [ ! -f build/w5100_spi.ko ]; then
    echo "ERROR: Build succeeded but .ko files not found. Check kernel headers."
    exit 1
fi

# Backup original drivers (only if stock .ko.xz exists)
echo "[4/5] Backing up existing drivers..."
echo "  The following stock drivers will be backed up:"
[ -f "$WIZNET_DIR/w5100.ko.xz"     ] && echo "    - $WIZNET_DIR/w5100.ko.xz"
[ -f "$WIZNET_DIR/w5100-spi.ko.xz" ] && echo "    - $WIZNET_DIR/w5100-spi.ko.xz"
read -p "  Proceed with backup? (y/N): " confirm_backup
[[ "$confirm_backup" == "y" || "$confirm_backup" == "Y" ]] || { echo "Aborted."; exit 0; }

if [ -f "$WIZNET_DIR/w5100.ko.xz" ]; then
    sudo cp "$WIZNET_DIR/w5100.ko.xz" "$WIZNET_DIR/w5100.ko.xz.bak"
    sudo rm "$WIZNET_DIR/w5100.ko.xz"
    echo "  Backed up: w5100.ko.xz -> w5100.ko.xz.bak"
fi
if [ -f "$WIZNET_DIR/w5100-spi.ko.xz" ]; then
    sudo cp "$WIZNET_DIR/w5100-spi.ko.xz" "$WIZNET_DIR/w5100-spi.ko.xz.bak"
    sudo rm "$WIZNET_DIR/w5100-spi.ko.xz"
    echo "  Backed up: w5100-spi.ko.xz -> w5100-spi.ko.xz.bak"
fi

# Install
echo "[5/5] Installing driver..."
echo "  The stock drivers will be replaced with the optimized W5500 driver."
echo "  To revert, run: sudo ./install.sh -Remove"
read -p "  Proceed with installation? (y/N): " confirm_install
[[ "$confirm_install" == "y" || "$confirm_install" == "Y" ]] || { echo "Aborted."; exit 0; }

sudo cp build/w5100.ko     "$WIZNET_DIR/w5100.ko"
sudo cp build/w5100_spi.ko "$WIZNET_DIR/w5100_spi.ko"
sudo depmod -a

echo ""
echo "=== Installation complete ==="
echo "To revert to the original driver:"
echo "  sudo rm $WIZNET_DIR/w5100.ko $WIZNET_DIR/w5100_spi.ko"
echo "  sudo mv $WIZNET_DIR/w5100.ko.xz.bak     $WIZNET_DIR/w5100.ko.xz"
echo "  sudo mv $WIZNET_DIR/w5100-spi.ko.xz.bak $WIZNET_DIR/w5100-spi.ko.xz"
echo "  sudo depmod -a && sudo reboot"
echo ""
read -p "Reboot now? (y/N): " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] && sudo reboot
