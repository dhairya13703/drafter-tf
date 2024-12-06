#!/bin/bash

# Function to handle errors
handle_error() {
    echo "Error occurred in script at line $1"
    # Kill all background processes
    kill $(jobs -p) 2>/dev/null
    exit 1
}

# Set error handling
trap 'handle_error $LINENO' ERR

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to wait for a service to be ready
wait_for_service() {
    local port=$1
    local service=$2
    local max_attempts=30
    local attempt=1
    
    echo "Waiting for $service to be ready..."
    while ! nc -z localhost $port && [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts: $service not ready yet..."
        sleep 2
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        echo "$service did not become ready in time"
        return 1
    fi
    echo "$service is ready!"
}

# Create log directory
mkdir -p logs

echo "Starting Drafter installation and setup..."

# Step 1: Install required packages
echo "Installing required packages..."
if command_exists dnf; then
    sudo dnf install -y redis nc curl iptables
elif command_exists apt; then
    sudo apt update
    sudo apt install -y redis-tools netcat curl iptables
fi

# Create installation directory
mkdir -p /tmp/drafter-install

# Step 2: Download and install Drafter binaries
echo "Installing Drafter binaries..."
for BINARY in drafter-nat drafter-forwarder drafter-snapshotter drafter-packager drafter-runner drafter-registry drafter-mounter drafter-peer drafter-terminator; do
    echo "Downloading $BINARY..."
    curl -L -o "/tmp/drafter-install/${BINARY}" "https://github.com/loopholelabs/drafter/releases/latest/download/${BINARY}.linux-$(uname -m)"
    sudo install -v "/tmp/drafter-install/${BINARY}" /usr/local/bin
done

# Download and install Firecracker
for BINARY in firecracker jailer; do
    echo "Downloading $BINARY..."
    curl -L -o "/tmp/drafter-install/${BINARY}" "https://github.com/loopholelabs/firecracker/releases/download/release-main-live-migration-pvm/${BINARY}.linux-$(uname -m)"
    sudo install -v "/tmp/drafter-install/${BINARY}" /usr/local/bin
done

# Configure sudo path
sudo tee /etc/sudoers.d/preserve_path << EOF
Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin
EOF

# Load NBD module
sudo modprobe nbd nbds_max=4096

# Clean up installation files
rm -rf /tmp/drafter-install

# Prepare working directories
echo "Preparing working directories..."
mkdir -p out/blueprint out/package out/instance-0/{overlay,state}

# Download and extract DrafterOS
echo "Downloading and extracting DrafterOS..."
curl -L -o out/drafteros-oci.tar.zst "https://github.com/loopholelabs/drafter/releases/latest/download/drafteros-oci-$(uname -m)_pvm.tar.zst"
curl -Lo out/oci-valkey.tar.zst "https://github.com/loopholelabs/drafter/releases/latest/download/oci-valkey-$(uname -m).tar.zst"

# Extract DrafterOS blueprint
sudo drafter-packager --package-path out/drafteros-oci.tar.zst --extract --devices '[
  {
    "name": "kernel",
    "path": "out/blueprint/vmlinux"
  },
  {
    "name": "disk",
    "path": "out/blueprint/rootfs.ext4"
  }
]'

sudo drafter-packager --package-path out/oci-valkey.tar.zst --extract --devices '[
  {
    "name": "oci",
    "path": "out/blueprint/oci.ext4"
  }
]'

# Start NAT service
sudo drafter-nat --host-interface eth0 &
sleep 15  # Wait for NAT to initialize

# Create initial snapshot
sudo drafter-snapshotter --netns ark0 --cpu-template T2A --devices '[
  {
    "name": "state",
    "output": "out/package/state.bin"
  },
  {
    "name": "memory",
    "output": "out/package/memory.bin"
  },
  {
    "name": "kernel",
    "input": "out/blueprint/vmlinux",
    "output": "out/package/vmlinux"
  },
  {
    "name": "disk",
    "input": "out/blueprint/rootfs.ext4",
    "output": "out/package/rootfs.ext4"
  },
  {
    "name": "config",
    "output": "out/package/config.json"
  },
  {
    "name": "oci",
    "input": "out/blueprint/oci.ext4",
    "output": "out/package/oci.ext4"
  }
]' &
sleep 30  # Wait for snapshotter to complete

# Start services in background
echo "Starting services..."

# Start NAT (replace eth0 with appropriate interface if needed)
sudo drafter-nat --host-interface eth0 > logs/nat.log 2>&1 &
NAT_PID=$!
echo "NAT service started with PID: $NAT_PID"

# Wait a bit for NAT to initialize
sleep 2

# Start drafter-peer
echo "Starting drafter-peer..."
sudo drafter-peer --netns ark0 --raddr '' --laddr ':1337' --devices '[
  {
    "name": "state",
    "base": "out/package/state.bin",
    "overlay": "out/instance-0/overlay/state.bin",
    "state": "out/instance-0/state/state.bin",
    "blockSize": 65536,
    "expiry": 1000000000,
    "maxDirtyBlocks": 200,
    "minCycles": 5,
    "maxCycles": 20,
    "cycleThrottle": 500000000,
    "makeMigratable": true,
    "shared": false
  },
  {
    "name": "memory",
    "base": "out/package/memory.bin",
    "overlay": "out/instance-0/overlay/memory.bin",
    "state": "out/instance-0/state/memory.bin",
    "blockSize": 65536,
    "expiry": 1000000000,
    "maxDirtyBlocks": 200,
    "minCycles": 5,
    "maxCycles": 20,
    "cycleThrottle": 500000000,
    "makeMigratable": true,
    "shared": false
  },
  {
    "name": "kernel",
    "base": "out/package/vmlinux",
    "overlay": "out/instance-0/overlay/vmlinux",
    "state": "out/instance-0/state/vmlinux",
    "blockSize": 65536,
    "expiry": 1000000000,
    "maxDirtyBlocks": 200,
    "minCycles": 5,
    "maxCycles": 20,
    "cycleThrottle": 500000000,
    "makeMigratable": true,
    "shared": false
  },
  {
    "name": "disk",
    "base": "out/package/rootfs.ext4",
    "overlay": "out/instance-0/overlay/rootfs.ext4",
    "state": "out/instance-0/state/rootfs.ext4",
    "blockSize": 65536,
    "expiry": 1000000000,
    "maxDirtyBlocks": 200,
    "minCycles": 5,
    "maxCycles": 20,
    "cycleThrottle": 500000000,
    "makeMigratable": true,
    "shared": false
  },
  {
    "name": "config",
    "base": "out/package/config.json",
    "overlay": "out/instance-0/overlay/config.json",
    "state": "out/instance-0/state/config.json",
    "blockSize": 65536,
    "expiry": 1000000000,
    "maxDirtyBlocks": 200,
    "minCycles": 5,
    "maxCycles": 20,
    "cycleThrottle": 500000000,
    "makeMigratable": true,
    "shared": false
  },
  {
    "name": "oci",
    "base": "out/package/oci.ext4",
    "overlay": "out/instance-0/overlay/oci.ext4",
    "state": "out/instance-0/state/oci.ext4",
    "blockSize": 65536,
    "expiry": 1000000000,
    "maxDirtyBlocks": 200,
    "minCycles": 5,
    "maxCycles": 20,
    "cycleThrottle": 500000000,
    "makeMigratable": true,
    "shared": false
  }
]' > logs/peer.log 2>&1 &
PEER_PID=$!

# Start port forwarding
echo "Setting up port forwarding..."
sudo drafter-forwarder --port-forwards '[
  {
    "netns": "ark0",
    "internalPort": "6379",
    "protocol": "tcp",
    "externalAddr": "127.0.0.1:3333"
  }
]' > logs/forwarder.log 2>&1 &
FORWARDER_PID=$!

# Wait for Redis to be available
wait_for_service 3333 "Redis"

# Initialize Redis with dummy data
echo "Initializing Redis with dummy data..."
redis-cli -p 3333 << EOF
SET message "Hello from Rocky Linux!"
SET user "rockyuser"
SET counter 42
EOF

# Verify Redis data
echo "Verifying Redis data..."
redis-cli -p 3333 KEYS '*'
redis-cli -p 3333 GET message
redis-cli -p 3333 GET user
redis-cli -p 3333 GET counter

echo "Setup complete! Services are running in the background."
echo "NAT PID: $NAT_PID"
echo "Peer PID: $PEER_PID"
echo "Forwarder PID: $FORWARDER_PID"
echo "Log files are available in the logs directory"

# Function to clean up processes
cleanup() {
    echo "Cleaning up processes..."
    kill $NAT_PID $PEER_PID $FORWARDER_PID 2>/dev/null
    wait
    echo "Cleanup complete"
}

# Set up cleanup on script exit
trap cleanup EXIT

# Keep script running until manually terminated
echo "Press Ctrl+C to stop all services and exit"
while true; do
    sleep 1
done