#!/bin/bash
# build-iptable-raw.sh
# Builds and installs iptable_raw.ko for Jetson Thor (JetPack 7.1 / L4T 38.4)
# Required because CONFIG_IP_NF_RAW=n in the stock Thor kernel
#
# Note: HEADERS_DIR assumes ubuntu24.04_aarch64 — update if using a different
# distro variant or JetPack release.

set -e

KERNEL_VERSION=$(uname -r)
SOURCE_URL="https://developer.nvidia.com/downloads/embedded/L4T/r38_Release_v4.0/source/public_sources.tbz2"
SOURCE_DIR="/usr/src/jetson-kernel"
KERNEL_SRC="${SOURCE_DIR}/Linux_for_Tegra/source/kernel/kernel-noble"
HEADERS_DIR="/usr/src/linux-headers-${KERNEL_VERSION}-ubuntu24.04_aarch64/3rdparty/canonical/linux-noble"
SYMVERS="${HEADERS_DIR}/Module.symvers"
BUILD_DIR="/tmp/iptable_raw"
MODULE_DEST="/lib/modules/${KERNEL_VERSION}/kernel/net/ipv4/netfilter"

echo "==> Building iptable_raw.ko for kernel ${KERNEL_VERSION}"

echo "==> Checking build dependencies"
for pkg in build-essential bc bison flex libssl-dev libelf-dev; do
    dpkg -s "$pkg" &>/dev/null || { echo "Missing package: $pkg — run: sudo apt install $pkg"; exit 1; }
done

echo "==> Checking kernel headers"
if [ ! -d "$HEADERS_DIR" ]; then
    echo "ERROR: Headers not found at $HEADERS_DIR"
    exit 1
fi

echo "==> Downloading BSP sources (~500MB)"
sudo mkdir -p "$SOURCE_DIR"
cd "$SOURCE_DIR"
sudo wget --timestamping --show-progress "$SOURCE_URL"

echo "==> Extracting BSP sources"
sudo tar -xjf public_sources.tbz2

echo "==> Extracting kernel source"
cd Linux_for_Tegra/source
sudo tar -xjf kernel_src.tbz2

echo "==> Verifying kernel source path"
if [ ! -f "${KERNEL_SRC}/net/ipv4/netfilter/iptable_raw.c" ]; then
    echo "ERROR: iptable_raw.c not found at expected path"
    exit 1
fi

echo "==> Setting up out-of-tree build directory"
mkdir -p "$BUILD_DIR"
cp "${KERNEL_SRC}/net/ipv4/netfilter/iptable_raw.c" "$BUILD_DIR/"

echo "==> Copying Module.symvers to set kernel symbol versions"
cp "$SYMVERS" "$BUILD_DIR/Module.symvers"

cat << 'EOF' > "$BUILD_DIR/Makefile"
obj-m := iptable_raw.o
EOF

echo "==> Building iptable_raw.ko"
make -C "$HEADERS_DIR" M="$BUILD_DIR" modules

echo "==> Verifying module magic"
modinfo "$BUILD_DIR/iptable_raw.ko" | grep -E "filename|vermagic"

echo "==> Installing module"
sudo mkdir -p "$MODULE_DEST"
sudo cp "$BUILD_DIR/iptable_raw.ko" "$MODULE_DEST/"
sudo depmod -a

echo "==> Loading module"
sudo modprobe iptable_raw

echo "==> Verifying"
lsmod | grep iptable_raw && echo "iptable_raw loaded successfully"

echo "==> Done"
echo "    Kernel source remains at: ${SOURCE_DIR}"
echo "    BSP tarball remains at:   ${SOURCE_DIR}/public_sources.tbz2"