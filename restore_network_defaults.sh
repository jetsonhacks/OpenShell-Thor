#!/bin/bash
# restore-network-defaults.sh
# Restores network stack to JetPack 7.1 defaults after running setup-openshell-network.sh
# Stops and destroys the OpenShell gateway before restoring network settings.

set -e

echo "==> Stopping OpenShell gateway"
if command -v openshell &>/dev/null; then
    openshell gateway stop 2>/dev/null || true
    docker rm -f $(docker ps -aq --filter name=openshell) 2>/dev/null || true
    docker network prune -f 2>/dev/null || true
else
    echo "    OpenShell not found, skipping gateway shutdown."
fi

echo "==> Flushing iptables rules"
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

echo "==> Restoring iptables-nft backend"
sudo update-alternatives --set iptables /usr/sbin/iptables-nft
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft

echo "==> Removing persistence configs"
sudo rm -f /etc/modules-load.d/openshell-k3s.conf
sudo rm -f /etc/sysctl.d/99-openshell-k3s.conf

echo "==> Restoring Docker daemon defaults (IPv6 + cgroupns mode)"
sudo python3 -c "
import json
config_path = '/etc/docker/daemon.json'
try:
    with open(config_path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
config.pop('ipv6', None)
config.pop('default-cgroupns-mode', None)
with open(config_path, 'w') as f:
    json.dump(config, f, indent=4)
    f.write('\n')
"

echo "==> Restarting Docker"
sudo systemctl restart docker

echo "==> Unloading kernel modules"
sleep 1
sudo modprobe -r br_netfilter 2>/dev/null || true
sudo modprobe -r iptable_raw 2>/dev/null || true

echo "==> Verifying"
sleep 1
update-alternatives --display iptables | grep "currently points to"
lsmod | grep -E "iptable_raw|br_netfilter" && echo "WARNING: modules still loaded" || echo "modules unloaded OK"
python3 -c "
import json
c = json.load(open('/etc/docker/daemon.json'))
print('Docker IPv6:', c.get('ipv6', 'not set (default)'))
print('Docker cgroupns mode:', c.get('default-cgroupns-mode', 'not set (default)'))
"

echo "==> Done. Reboot recommended to fully restore default state."