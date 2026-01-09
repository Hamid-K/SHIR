#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/pi-setup.sh"
  exit 1
fi

read -r -p "Starlink interface name [eth0]: " STARLINK_IFACE
STARLINK_IFACE=${STARLINK_IFACE:-eth0}

read -r -p "SIM interface name [wlan0]: " SIM_IFACE
SIM_IFACE=${SIM_IFACE:-wlan0}

read -r -p "VPS public IP (Iran) [203.0.113.10]: " VPS_IP
VPS_IP=${VPS_IP:-203.0.113.10}

read -r -p "VPS WireGuard bootstrap port [51821]: " VPS_WG1_PORT
VPS_WG1_PORT=${VPS_WG1_PORT:-51821}

read -r -p "VPS wg1 public key: " VPS_WG1_PUBLIC_KEY

read -r -p "NordVPN token: " NORDVPN_TOKEN

read -r -p "Meshnet interface name [nordlynx]: " MESH_IFACE
MESH_IFACE=${MESH_IFACE:-nordlynx}

apt-get update
apt-get install -y wireguard iptables-persistent curl

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ipforward.conf
sysctl --system

# Install NordVPN CLI
curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh

# Login and enable Meshnet
nordvpn login --token "${NORDVPN_TOKEN}"
nordvpn set meshnet on
nordvpn meshnet set allow-incoming on
nordvpn meshnet set allow-routing on

# Generate keys
umask 077
wg genkey | tee /root/pi_wg1_private.key | wg pubkey > /root/pi_wg1_public.key
PI_WG1_PRIVATE_KEY=$(cat /root/pi_wg1_private.key)

# Configure wg1
cat > /etc/wireguard/wg1.conf <<CONF
[Interface]
Address = 10.200.0.2/30
PrivateKey = ${PI_WG1_PRIVATE_KEY}

[Peer]
PublicKey = ${VPS_WG1_PUBLIC_KEY}
Endpoint = ${VPS_IP}:${VPS_WG1_PORT}
AllowedIPs = 10.200.0.1/32
PersistentKeepalive = 25
CONF

systemctl enable --now wg-quick@wg1

# NAT from Meshnet to Starlink
iptables -t nat -A POSTROUTING -o "${STARLINK_IFACE}" -j MASQUERADE
iptables -A FORWARD -i "${MESH_IFACE}" -o "${STARLINK_IFACE}" -j ACCEPT
iptables -A FORWARD -i "${STARLINK_IFACE}" -o "${MESH_IFACE}" -m state --state ESTABLISHED,RELATED -j ACCEPT
netfilter-persistent save

cat <<INFO

Pi setup complete.

Pi wg1 public key:
$(cat /root/pi_wg1_public.key)

Next:
- Add this public key to VPS wg1 peer.
- Ensure Meshnet shows the Pi device and allows routing.
INFO
