#!/bin/bash

# Exit on any error
set -e

echo "Starting Drafter tools installation..."

# Create temporary directory
INSTALL_DIR="/tmp/drafter-install"
mkdir -p "$INSTALL_DIR"

# Get system architecture
ARCH=$(uname -m)

# Install Drafter binaries
DRAFTER_BINARIES=(
    "drafter-nat"
    "drafter-forwarder"
    "drafter-snapshotter"
    "drafter-packager"
    "drafter-runner"
    "drafter-registry"
    "drafter-mounter"
    "drafter-peer"
    "drafter-terminator"
)

for BINARY in "${DRAFTER_BINARIES[@]}"; do
    echo "Downloading $BINARY..."
    wget -q -O "$INSTALL_DIR/$BINARY" "https://github.com/loopholelabs/drafter/releases/latest/download/$BINARY.linux-$ARCH"
    chmod +x "$INSTALL_DIR/$BINARY"
    echo "Installing $BINARY..."
    sudo install -v "$INSTALL_DIR/$BINARY" /usr/local/bin
done

# Install Firecracker with PVM support
FIRECRACKER_BINARIES=(
    "firecracker"
    "jailer"
)

for BINARY in "${FIRECRACKER_BINARIES[@]}"; do
    echo "Downloading $BINARY..."
    wget -q -O "$INSTALL_DIR/$BINARY" "https://github.com/loopholelabs/firecracker/releases/download/release-main-live-migration-pvm/$BINARY.linux-$ARCH"
    chmod +x "$INSTALL_DIR/$BINARY"
    echo "Installing $BINARY..."
    sudo install -v "$INSTALL_DIR/$BINARY" /usr/local/bin
done

# Configure sudo path
echo "Configuring sudo path..."
echo 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' | sudo tee /etc/sudoers.d/preserve_path > /dev/null

# Clean up
rm -rf "$INSTALL_DIR"

echo "Installation completed successfully!"
