#!/bin/bash

# Check if source VM IP is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <source_vm_ip>"
    echo "Example: $0 192.168.1.100"
    exit 1
fi

SOURCE_VM_IP=$1

# Function to handle errors
handle_error() {
    echo "Error occurred in script at line $1"
    # Kill all background processes
    kill $(jobs -p) 2>/dev/null
    exit 1
}

# Set error handling
trap 'handle_error $LINENO' ERR

# Function to wait for a service to be ready
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


echo "Starting migration setup for destination server..."
echo "Source VM IP: $SOURCE_VM_IP"

# Create required directories
echo "Creating directories..."
mkdir -p out/instance-1/{overlay,state}

# Start NAT service
echo "Starting NAT service..."
sudo drafter-nat --host-interface eth0 > logs/nat.log 2>&1 &
NAT_PID=$!
echo "NAT service started with PID: $NAT_PID"

# Wait for NAT to initialize
sleep 10

# Start migration receiver
echo "Starting migration receiver..."
sudo drafter-peer --netns ark1 --raddr "${SOURCE_VM_IP}:1337" --laddr '' --devices '[
  {
    "name": "state",
    "base": "out/package/state.bin",
    "overlay": "out/instance-1/overlay/state.bin",
    "state": "out/instance-1/state/state.bin",
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
    "overlay": "out/instance-1/overlay/memory.bin",
    "state": "out/instance-1/state/memory.bin",
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
    "overlay": "out/instance-1/overlay/vmlinux",
    "state": "out/instance-1/state/vmlinux",
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
    "overlay": "out/instance-1/overlay/rootfs.ext4",
    "state": "out/instance-1/state/rootfs.ext4",
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
    "overlay": "out/instance-1/overlay/config.json",
    "state": "out/instance-1/state/config.json",
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
    "overlay": "out/instance-1/overlay/oci.ext4",
    "state": "out/instance-1/state/oci.ext4",
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
    "netns": "ark1",
    "internalPort": "6379",
    "protocol": "tcp",
    "externalAddr": "127.0.0.1:3333"
  }
]' > logs/forwarder.log 2>&1 &
FORWARDER_PID=$!

# Wait for Redis to become available
wait_for_service 3333 "Redis"

# Verify Redis data
echo "Verifying Redis data..."
echo "Testing Redis connection..."
if redis-cli -p 3333 ping > /dev/null 2>&1; then
    echo "Redis is accessible. Checking migrated data..."
    
    # Get and display all keys
    echo "Keys in Redis:"
    redis-cli -p 3333 KEYS '*'
    
    # Check specific values
    echo -n "message: "
    redis-cli -p 3333 GET message
    echo -n "user: "
    redis-cli -p 3333 GET user
    echo -n "counter: "
    redis-cli -p 3333 GET counter
else
    echo "Warning: Could not connect to Redis"
fi

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
