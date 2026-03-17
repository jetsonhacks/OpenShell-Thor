#!/bin/bash
# setup-openshell-network.sh
# Configures network prerequisites for OpenShell on Jetson Thor (JetPack 7.1 / L4T 38.4)
# - Switches iptables to legacy backend (required for K3s service routing)
# - Loads br_netfilter (required for K3s flannel CNI pod networking)
# - Disables IPv6 in Docker daemon (required for K3s containerd image pulls)
# - Sets default-cgroupns-mode=host in Docker daemon (required for K3s cgroup v2 access)
# - Persists all changes across reboots

set -e

echo "==> Checking iptable_raw module"
if ! modinfo iptable_raw &>/dev/null; then
    echo "ERROR: iptable_raw module not found."
    echo "       Run build-iptable-raw.sh first."
    exit 1
fi

echo "==> Switching iptables to legacy backend"
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

echo "==> Flushing existing iptables rules"
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
sudo iptables -t raw -F
sudo iptables -t raw -X
sudo ip6tables -F
sudo ip6tables -X
sudo ip6tables -t nat -F
sudo ip6tables -t nat -X

echo "==> Loading kernel modules"
sudo modprobe iptable_raw
sudo modprobe br_netfilter

echo "==> Setting bridge sysctls"
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1

echo "==> Persisting modules across reboots"
cat << 'EOF' | sudo tee /etc/modules-load.d/openshell-k3s.conf
iptable_raw
br_netfilter
EOF

echo "==> Persisting sysctls across reboots"
cat << 'EOF' | sudo tee /etc/sysctl.d/99-openshell-k3s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

echo "==> Configuring Docker daemon (IPv6 + cgroupns mode)"
sudo python3 -c "
import json
config_path = '/etc/docker/daemon.json'
try:
    with open(config_path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
config['ipv6'] = False
config['default-cgroupns-mode'] = 'host'
with open(config_path, 'w') as f:
    json.dump(config, f, indent=4)
    f.write('\n')
"

echo "==> Restarting Docker"
sudo systemctl restart docker

echo "==> Verifying"
sudo iptables -t raw -L > /dev/null && echo "raw table OK"
sudo iptables -t nat -L DOCKER > /dev/null && echo "DOCKER chain OK"
lsmod | grep -E "iptable_raw|br_netfilter"
sysctl net.bridge.bridge-nf-call-iptables
python3 -c "
import json
c = json.load(open('/etc/docker/daemon.json'))
print('Docker IPv6:', c.get('ipv6'))
print('Docker cgroupns mode:', c.get('default-cgroupns-mode'))
"

echo "==> Done. Reboot recommended before starting OpenShell."