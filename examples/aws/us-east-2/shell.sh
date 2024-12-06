export HOSTS=(
  # AWS Servers - us_east_2
  "ec2-user@18.217.252.8"

  # Azure Servers - Central US
  "azure-user@104.208.29.229"

  # GCP Servers - us_east4_b
  "gcp-user@34.145.255.221"

  # Hetzner Servers - HIL
  "root@5.78.120.0"
)

parallel --ungroup --jobs 1 'ssh -o StrictHostKeychecking=no -tt {} "uname -r && cat /proc/cpuinfo | grep \\"model name\\|address sizes\\" | sort | uniq && sudo dmidecode -t processor | grep \\"Max Speed\\" | sort | uniq && systemd-detect-virt && ls /sys/module/ | grep kvm"' ::: "${HOSTS[@]}"

ssh -tt ${HOSTS[0]} "sudo drafter-nat --host-interface eth0"
ssh -tt ${HOSTS[1]} "sudo drafter-nat --host-interface eth0"
ssh -tt ${HOSTS[2]} "sudo drafter-nat --host-interface eth0"
ssh -tt ${HOSTS[3]} "sudo drafter-nat --host-interface eth0"

# For AWS, we need to use the internal IP since traffic from the public IP gets it's IP rewritten to the internal one before arriving at the NAT
ssh -tt "${HOSTS[0]}" "sudo drafter-forwarder --port-forwards '[
  {
    \\"netns\\": \\"ark0\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"127.0.0.1:3333\\"
  },
  {
    \\"netns\\": \\"ark0\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"10.0.1.14:3333\\"
  }
]'"
# For Azure, we need to use the internal IP since traffic from the public IP gets it's IP rewritten to the internal one before arriving at the NAT
ssh -tt "${HOSTS[1]}" "sudo drafter-forwarder --port-forwards '[
  {
    \\"netns\\": \\"ark1\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"127.0.0.1:3333\\"
  },
  {
    \\"netns\\": \\"ark1\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"10.0.1.4:3333\\"
  }
]'"
# For GCP, we need to use the internal IP since traffic from the public IP gets it's IP rewritten to the internal one before arriving at the NAT
ssh -tt "${HOSTS[2]}" "sudo drafter-forwarder --port-forwards '[
  {
    \\"netns\\": \\"ark1\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"127.0.0.1:3333\\"
  },
  {
    \\"netns\\": \\"ark1\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"10.2.0.2:3333\\"
  }
]'"
ssh -tt "${HOSTS[3]}" "sudo drafter-forwarder --port-forwards '[
  {
    \\"netns\\": \\"ark1\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"127.0.0.1:3333\\"
  },
  {
    \\"netns\\": \\"ark1\\",
    \\"internalPort\\": \\"6379\\",
    \\"protocol\\": \\"tcp\\",
    \\"externalAddr\\": \\"${HOSTS[3]#*@}:3333\\"
  }
]'"

# make depend/os OS_DEFCONFIG=drafteros-oci-firecracker-x86_64_pvm_defconfig
curl -L -o out/drafteros-oci.tar.zst "https://github.com/loopholelabs/drafter/releases/latest/download/drafteros-oci-$(uname -m)_pvm.tar.zst"

mv ~/Downloads/buildroot.oci/ out/buildroot; make build/os && sudo make build/oci OCI_IMAGE_URI=docker://valkey/valkey:latest OCI_IMAGE_ARCHITECTURE=amd64 && mv out/buildroot/ ~/Downloads/buildroot.oci && parallel --ungroup --jobs 0 'rsync -a --delete --progress --compress --compress-choice=zstd --mkpath "out/blueprint/" {}:out/blueprint/oci' ::: "${HOSTS[@]}"

# Create snapshot & start it on first cloud host (AWS)
# Use the T2CL CPU template Intel and on T2A on AMD (at least AMD Milan)
ssh -tt ${HOSTS[0]} "sudo rmmod kvm_pvm && sudo modprobe kvm_pvm && sudo drafter-snapshotter --cpu-template T2A --cpu-count 4 -memory-size 2048 --netns ark0 --devices '[
  {
    \\"name\\": \\"state\\",
    \\"output\\": \\"out/package/oci/state.bin\\"
  },
  {
    \\"name\\": \\"memory\\",
    \\"output\\": \\"out/package/oci/memory.bin\\"
  },
  {
    \\"name\\": \\"kernel\\",
    \\"input\\": \\"out/blueprint/oci/vmlinux\\",
    \\"output\\": \\"out/package/oci/vmlinux\\"
  },
  {
    \\"name\\": \\"disk\\",
    \\"input\\": \\"out/blueprint/oci/rootfs.ext4\\",
    \\"output\\": \\"out/package/oci/rootfs.ext4\\"
  },
  {
    \\"name\\": \\"config\\",
    \\"output\\": \\"out/package/oci/config.json\\"
  },
  {
    \\"name\\": \\"oci\\",
    \\"input\\": \\"out/blueprint/oci/oci.ext4\\",
    \\"output\\": \\"out/package/oci/oci.ext4\\"
  }
]' && sudo rm -rf out/instance-0/oci && sudo drafter-peer --netns ark0 --raddr '' --laddr '0.0.0.0:1337' --devices '[
  {
    \\"name\\": \\"state\\",
    \\"base\\": \\"out/package/oci/state.bin\\",
    \\"overlay\\": \\"out/instance-0/oci/overlay/state.bin\\",
    \\"state\\": \\"out/instance-0/oci/state/state.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"memory\\",
    \\"base\\": \\"out/package/oci/memory.bin\\",
    \\"overlay\\": \\"out/instance-0/oci/overlay/memory.bin\\",
    \\"state\\": \\"out/instance-0/oci/state/memory.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"kernel\\",
    \\"base\\": \\"out/package/oci/vmlinux\\",
    \\"overlay\\": \\"out/instance-0/oci/overlay/vmlinux\\",
    \\"state\\": \\"out/instance-0/oci/state/vmlinux\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"disk\\",
    \\"base\\": \\"out/package/oci/rootfs.ext4\\",
    \\"overlay\\": \\"out/instance-0/oci/overlay/rootfs.ext4\\",
    \\"state\\": \\"out/instance-0/oci/state/rootfs.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"config\\",
    \\"base\\": \\"out/package/oci/config.json\\",
    \\"overlay\\": \\"out/instance-0/oci/overlay/config.json\\",
    \\"state\\": \\"out/instance-0/oci/state/config.json\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"oci\\",
    \\"base\\": \\"out/package/oci/oci.ext4\\",
    \\"overlay\\": \\"out/instance-0/oci/overlay/oci.ext4\\",
    \\"state\\": \\"out/instance-0/oci/state/oci.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  }
]'"

# Migrate snapshot to second cloud host (Azure)
ssh -tt ${HOSTS[1]} "sudo rmmod kvm_pvm && sudo modprobe kvm_pvm && sudo rm -rf out/instance-1/oci && sudo drafter-peer --netns ark1 --raddr '${HOSTS[0]#*@}:1337' --laddr '0.0.0.0:1337' --devices '[
  {
    \\"name\\": \\"state\\",
    \\"base\\": \\"out/package/oci/state.bin\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/state.bin\\",
    \\"state\\": \\"out/instance-1/oci/state/state.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"memory\\",
    \\"base\\": \\"out/package/oci/memory.bin\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/memory.bin\\",
    \\"state\\": \\"out/instance-1/oci/state/memory.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"kernel\\",
    \\"base\\": \\"out/package/oci/vmlinux\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/vmlinux\\",
    \\"state\\": \\"out/instance-1/oci/state/vmlinux\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"disk\\",
    \\"base\\": \\"out/package/oci/rootfs.ext4\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/rootfs.ext4\\",
    \\"state\\": \\"out/instance-1/oci/state/rootfs.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"config\\",
    \\"base\\": \\"out/package/oci/config.json\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/config.json\\",
    \\"state\\": \\"out/instance-1/oci/state/config.json\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"oci\\",
    \\"base\\": \\"out/package/oci/oci.ext4\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/oci.ext4\\",
    \\"state\\": \\"out/instance-1/oci/state/oci.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  }
]'"

# Migrate snapshot to third cloud host (GCP)
ssh -tt ${HOSTS[2]} "sudo rmmod kvm_pvm && sudo modprobe kvm_pvm && sudo rm -rf out/instance-1/oci && sudo drafter-peer --netns ark1 --raddr '${HOSTS[1]#*@}:1337' --laddr '0.0.0.0:1337' --devices '[
  {
    \\"name\\": \\"state\\",
    \\"base\\": \\"out/package/oci/state.bin\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/state.bin\\",
    \\"state\\": \\"out/instance-1/oci/state/state.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"memory\\",
    \\"base\\": \\"out/package/oci/memory.bin\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/memory.bin\\",
    \\"state\\": \\"out/instance-1/oci/state/memory.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"kernel\\",
    \\"base\\": \\"out/package/oci/vmlinux\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/vmlinux\\",
    \\"state\\": \\"out/instance-1/oci/state/vmlinux\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"disk\\",
    \\"base\\": \\"out/package/oci/rootfs.ext4\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/rootfs.ext4\\",
    \\"state\\": \\"out/instance-1/oci/state/rootfs.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"config\\",
    \\"base\\": \\"out/package/oci/config.json\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/config.json\\",
    \\"state\\": \\"out/instance-1/oci/state/config.json\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"oci\\",
    \\"base\\": \\"out/package/oci/oci.ext4\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/oci.ext4\\",
    \\"state\\": \\"out/instance-1/oci/state/oci.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  }
]'"

# # Migrate snapshot to fourth cloud host (Hetzner)
# ssh -tt ${HOSTS[3]} "sudo rmmod kvm_pvm && sudo modprobe kvm_pvm && sudo rm -rf out/instance-1/oci && sudo drafter-peer --netns ark1 --raddr '${HOSTS[2]#*@}:1337' --laddr '0.0.0.0:1337' --devices '[
#   {
#     \\"name\\": \\"state\\",
#     \\"base\\": \\"out/package/oci/state.bin\\",
#     \\"overlay\\": \\"out/instance-1/oci/overlay/state.bin\\",
#     \\"state\\": \\"out/instance-1/oci/state/state.bin\\",
#     \\"blockSize\\": 65536,
#     \\"expiry\\": 1000000000,
#     \\"maxDirtyBlocks\\": 200,
#     \\"minCycles\\": 5,
#     \\"maxCycles\\": 20,
#     \\"cycleThrottle\\": 500000000,
#     \\"makeMigratable\\": true,
#     \\"shared\\": false
#   },
#   {
#     \\"name\\": \\"memory\\",
#     \\"base\\": \\"out/package/oci/memory.bin\\",
#     \\"overlay\\": \\"out/instance-1/oci/overlay/memory.bin\\",
#     \\"state\\": \\"out/instance-1/oci/state/memory.bin\\",
#     \\"blockSize\\": 65536,
#     \\"expiry\\": 1000000000,
#     \\"maxDirtyBlocks\\": 200,
#     \\"minCycles\\": 5,
#     \\"maxCycles\\": 20,
#     \\"cycleThrottle\\": 500000000,
#     \\"makeMigratable\\": true,
#     \\"shared\\": false
#   },
#   {
#     \\"name\\": \\"kernel\\",
#     \\"base\\": \\"out/package/oci/vmlinux\\",
#     \\"overlay\\": \\"out/instance-1/oci/overlay/vmlinux\\",
#     \\"state\\": \\"out/instance-1/oci/state/vmlinux\\",
#     \\"blockSize\\": 65536,
#     \\"expiry\\": 1000000000,
#     \\"maxDirtyBlocks\\": 200,
#     \\"minCycles\\": 5,
#     \\"maxCycles\\": 20,
#     \\"cycleThrottle\\": 500000000,
#     \\"makeMigratable\\": true,
#     \\"shared\\": false
#   },
#   {
#     \\"name\\": \\"disk\\",
#     \\"base\\": \\"out/package/oci/rootfs.ext4\\",
#     \\"overlay\\": \\"out/instance-1/oci/overlay/rootfs.ext4\\",
#     \\"state\\": \\"out/instance-1/oci/state/rootfs.ext4\\",
#     \\"blockSize\\": 65536,
#     \\"expiry\\": 1000000000,
#     \\"maxDirtyBlocks\\": 200,
#     \\"minCycles\\": 5,
#     \\"maxCycles\\": 20,
#     \\"cycleThrottle\\": 500000000,
#     \\"makeMigratable\\": true,
#     \\"shared\\": false
#   },
#   {
#     \\"name\\": \\"config\\",
#     \\"base\\": \\"out/package/oci/config.json\\",
#     \\"overlay\\": \\"out/instance-1/oci/overlay/config.json\\",
#     \\"state\\": \\"out/instance-1/oci/state/config.json\\",
#     \\"blockSize\\": 65536,
#     \\"expiry\\": 1000000000,
#     \\"maxDirtyBlocks\\": 200,
#     \\"minCycles\\": 5,
#     \\"maxCycles\\": 20,
#     \\"cycleThrottle\\": 500000000,
#     \\"makeMigratable\\": true,
#     \\"shared\\": false
#   },
#   {
#     \\"name\\": \\"oci\\",
#     \\"base\\": \\"out/package/oci/oci.ext4\\",
#     \\"overlay\\": \\"out/instance-1/oci/overlay/oci.ext4\\",
#     \\"state\\": \\"out/instance-1/oci/state/oci.ext4\\",
#     \\"blockSize\\": 65536,
#     \\"expiry\\": 1000000000,
#     \\"maxDirtyBlocks\\": 200,
#     \\"minCycles\\": 5,
#     \\"maxCycles\\": 20,
#     \\"cycleThrottle\\": 500000000,
#     \\"makeMigratable\\": true,
#     \\"shared\\": false
#   }
# ]'"

# Migrate snapshot back to first cloud host (AWS)
ssh -tt ${HOSTS[0]} "sudo rmmod kvm_pvm && sudo modprobe kvm_pvm && sudo rm -rf out/instance-1/oci && sudo drafter-peer --netns ark0 --raddr '${HOSTS[2]#*@}:1337' --laddr '0.0.0.0:1337' --devices '[
  {
    \\"name\\": \\"state\\",
    \\"base\\": \\"out/package/oci/state.bin\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/state.bin\\",
    \\"state\\": \\"out/instance-1/oci/state/state.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"memory\\",
    \\"base\\": \\"out/package/oci/memory.bin\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/memory.bin\\",
    \\"state\\": \\"out/instance-1/oci/state/memory.bin\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"kernel\\",
    \\"base\\": \\"out/package/oci/vmlinux\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/vmlinux\\",
    \\"state\\": \\"out/instance-1/oci/state/vmlinux\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"disk\\",
    \\"base\\": \\"out/package/oci/rootfs.ext4\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/rootfs.ext4\\",
    \\"state\\": \\"out/instance-1/oci/state/rootfs.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"config\\",
    \\"base\\": \\"out/package/oci/config.json\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/config.json\\",
    \\"state\\": \\"out/instance-1/oci/state/config.json\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  },
  {
    \\"name\\": \\"oci\\",
    \\"base\\": \\"out/package/oci/oci.ext4\\",
    \\"overlay\\": \\"out/instance-1/oci/overlay/oci.ext4\\",
    \\"state\\": \\"out/instance-1/oci/state/oci.ext4\\",
    \\"blockSize\\": 65536,
    \\"expiry\\": 1000000000,
    \\"maxDirtyBlocks\\": 200,
    \\"minCycles\\": 5,
    \\"maxCycles\\": 20,
    \\"cycleThrottle\\": 500000000,
    \\"makeMigratable\\": true,
    \\"shared\\": false
  }
]'"
