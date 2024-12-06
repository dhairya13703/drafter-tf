mkdir -p /tmp/drafter-install

# Download and install Drafter binaries
for BINARY in drafter-nat drafter-forwarder drafter-snapshotter drafter-packager drafter-runner drafter-registry drafter-mounter drafter-peer drafter-terminator; do
    echo "Downloading $BINARY..."
    curl -L -o "/tmp/drafter-install/${BINARY}" "https://github.com/loopholelabs/drafter/releases/latest/download/${BINARY}.linux-$(uname -m)"
    echo "Installing $BINARY..."
    sudo install -v "/tmp/drafter-install/${BINARY}" /usr/local/bin
done

# Download and install Firecracker with PVM support
for BINARY in firecracker jailer; do
    echo "Downloading $BINARY..."
    curl -L -o "/tmp/drafter-install/${BINARY}" "https://github.com/loopholelabs/firecracker/releases/download/release-main-live-migration-pvm/${BINARY}.linux-$(uname -m)"
    echo "Installing $BINARY..."
    sudo install -v "/tmp/drafter-install/${BINARY}" /usr/local/bin
done

# Configure sudo path to include /usr/local/bin
sudo tee /etc/sudoers.d/preserve_path << EOF
Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/usr/local/sbin
EOF

# Load NBD module with increased device count
sudo modprobe nbd nbds_max=4096

# Clean up temporary files
rm -rf /tmp/drafter-install

# Verify installations
for CMD in drafter-nat drafter-forwarder drafter-snapshotter drafter-packager drafter-runner drafter-registry drafter-mounter drafter-peer drafter-terminator firecracker jailer; do
    echo "Checking $CMD version..."
    $CMD --version || echo "$CMD version check not supported"
done


Step 3: Preparing the Redis VM
# Install redis cli
sudo dnf install -y redis

### Preparing the Environment
# Create working directories
mkdir -p out/blueprint out/package out/instance-0/{overlay,state}

# Download DrafterOS with PVM support
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


Step 4: The Migration Process
The actual migration is remarkably simple:

On source instance:
Network Setup and Snapshot Creation

# Open new terminal. This will start NAT for network connectivity
sudo drafter-nat --host-interface eth0 # Replace eth0 with the network interface you want to route outgoing traffic from the VMs to

# Open new terminal and run it. This will create initial snapshot
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
]'

Starting Redis with Migration Support
#  Open new terminal and run it. This will start Redis with migration enabled
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
]'

Start port forwarding on source vm for redis

# Open new terminal and run it. This will set up port forwarding for Redis
sudo drafter-forwarder --port-forwards '[
  {
    "netns": "ark0",
    "internalPort": "6379",
    "protocol": "tcp",
    "externalAddr": "127.0.0.1:3333"
  }
]'

Connect to redis and add dummy data
redis-cli -p 3333 ping
redis-cli -p 3333

# Once connected, you can run these commands:
SET message "Hello from Rocky Linux!"
SET user "rockyuser"
SET counter 42

# Check the data
KEYS *
GET message
GET user
GET counter

