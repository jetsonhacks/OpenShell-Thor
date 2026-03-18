# OpenShell on Jetson Thor

Scripts to configure Jetson AGX Thor (JetPack 7.1 / L4T 38.4) to run
[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) — the secure
runtime for autonomous AI agents and the foundation of the NemoClaw stack.

OpenShell runs a K3s Kubernetes cluster inside a single Docker container.
The stock JetPack 7.1 configuration has five issues that prevent it from
running correctly. These scripts fix all five.

## Issues

### 1. Missing `iptable_raw` kernel module

OpenShell's network isolation policy uses the `raw` iptables table to
enforce sandbox egress filtering. The stock Thor kernel (6.8.12-tegra)
is built with `CONFIG_IP_NF_RAW=n`, meaning the module doesn't exist
and cannot be loaded.

**Fix:** Build and install `iptable_raw.ko` as an out-of-tree module
against the installed kernel headers.

### 2. iptables backend incompatible with K3s

JetPack 7.1 ships Ubuntu 24.04, which defaults to `iptables-nft` — a
compatibility wrapper over nftables. K3s writes legacy iptables rules
for its service routing and kube-proxy. With the nft backend, these
rules are written in a format that nftables silently drops, breaking
DNS resolution inside pods. The symptom is sandbox containers failing
to reach the OpenShell control plane with a DNS error.

**Fix:** Switch the system to `iptables-legacy`.

### 3. `br_netfilter` not loaded

K3s uses flannel for pod networking. Flannel requires `br_netfilter` to
be loaded and `net.bridge.bridge-nf-call-iptables=1` to be set before
the cluster starts. Without it, pod sandbox creation fails and all K3s
system pods stay in `ContainerCreating` indefinitely.

**Fix:** Load `br_netfilter` and set the bridge sysctls, with
persistence across reboots via `/etc/modules-load.d/` and
`/etc/sysctl.d/`.

### 4. IPv6 connectivity broken in gateway container

The OpenShell gateway runs K3s and containerd inside a Docker container.
When containerd pulls images from `docker.io` or `registry.k8s.io`, DNS
returns both IPv4 and IPv6 addresses. containerd prefers IPv6 by default,
but the gateway container has no IPv6 routing. All image pulls time out
waiting for IPv6 connections that never complete.

Images from `ghcr.io` are unaffected because OpenShell's `registries.yaml`
includes an explicit mirror entry for `ghcr.io` that forces a working
connection path. The missing entries for `docker.io` and `registry.k8s.io`
are a known issue with the current OpenShell gateway image.

**Workaround:** Disable IPv6 in the Docker daemon config. This causes
Docker bridge networks — including the gateway container's network — to
operate IPv4-only, so containerd connects directly to IPv4 endpoints
without attempting IPv6 first. This workaround will become unnecessary
once the OpenShell gateway image is updated to include explicit mirror
entries for `docker.io` and `registry.k8s.io`.

### 5. K3s cannot access cgroup v2 hierarchy inside gateway container

JetPack 7.1 uses cgroup v2. By default, Docker runs containers in
`private` cgroupns mode, which gives each container its own isolated
cgroup namespace. K3s inside the OpenShell gateway container expects to
read and write the host cgroup hierarchy directly (e.g.
`/sys/fs/cgroup/kubepods/pids.max`). With a private cgroup namespace
these paths don't exist inside the container, and K3s fails at startup
with:

```
openat2 /sys/fs/cgroup/kubepods/pids.max: no such file or directory
```

**Fix:** Set `"default-cgroupns-mode": "host"` in `/etc/docker/daemon.json`.
This makes all Docker containers (including the OpenShell gateway) use
the host cgroup namespace by default, giving K3s the visibility into the
cgroup hierarchy it requires.

## Scripts

| Script | Purpose |
|--------|---------|
| `build-iptable-raw.sh` | Downloads JetPack 7.1 kernel sources and builds `iptable_raw.ko` |
| `setup-openshell-network.sh` | Applies fixes 2–5 and persists them across reboots |
| `restore-network-defaults.sh` | Reverses all changes and restores JetPack defaults |

## Usage

### Prerequisites

Install build dependencies:
```bash
sudo apt install -y \
    build-essential bc bison flex libssl-dev libelf-dev
```

### Step 0 — Install OpenShell

Install the OpenShell CLI:
```bash
uv tool install -U openshell
```

The install script only installs the `openshell` CLI binary. The smoke
test in Step 3 uses an example that lives in the OpenShell repository
itself, so clone it somewhere convenient:
```bash
git clone https://github.com/NVIDIA/OpenShell
```

Steps 1 and 2 use scripts from this repository (`openshell-thor`), not
from the OpenShell clone.

### Step 1 — Build the kernel module
```bash
./build-iptable-raw.sh
```

This downloads the JetPack 7.1 BSP sources (~286MB), extracts the
kernel source, and builds `iptable_raw.ko` as an out-of-tree module
against the installed kernel headers. The module is installed and
loaded immediately.

Downloads are skipped if the source tarball is already present.

### Step 2 — Configure the network stack
```bash
./setup-openshell-network.sh
```

Then reboot:
```bash
sudo reboot
```

The reboot is required to ensure all kernel modules and sysctls load
cleanly from the persistence configs rather than relying on the current
session state.

### Step 3 — Run OpenShell

After rebooting, OpenShell should work. Run the smoke test from inside
the OpenShell repository cloned in Step 0:
```bash
cd OpenShell
bash examples/sandbox-policy-quickstart/demo.sh
```

### Restoring defaults

To undo all changes and return to stock JetPack configuration:
```bash
./restore-network-defaults.sh
sudo reboot
```

## Tested Configuration

| Component | Version |
|-----------|---------|
| Hardware | Jetson AGX Thor Developer Kit |
| JetPack | 7.1 |
| L4T | 38.4 |
| Kernel | 6.8.12-tegra |
| OpenShell | v0.0.6 |
| OS | Ubuntu 24.04 (Noble) |

## Notes

- The kernel source download (~286MB) is only needed for
  `build-iptable-raw.sh`. The extracted source is left in
  `/usr/src/jetson-kernel` for reference and future module builds.
- These fixes are specific to JetPack 7.1 on Thor. Future JetPack
  releases may address the missing `CONFIG_IP_NF_RAW` kernel option
  upstream.
- The IPv6 workaround disables IPv6 for all Docker bridge networks on
  the host, not just the OpenShell gateway. If your workload requires
  IPv6 in other Docker containers, consider the alternative fix of
  adding explicit mirror entries directly to the gateway container's
  `/etc/rancher/k3s/registries.yaml` after each gateway start.
- Setting `default-cgroupns-mode: host` applies to all Docker
  containers on the host, not just the OpenShell gateway. This is
  the correct default for cgroup v2 systems running K3s or other
  container-in-container workloads, but be aware if you have
  containers that rely on cgroup namespace isolation.

## Releases

### March, 2026
* Initial Release
* Tested on NVIDIA AGX Thor Developer Kit
* Added fix #5: Docker cgroupns mode for cgroup v2 compatibility