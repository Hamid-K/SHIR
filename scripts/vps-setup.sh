#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/vps-setup.sh"
  exit 1
fi

read -r -p "Public gateway IP for VPS (from provider): " VPS_PUBLIC_GATEWAY
read -r -p "Pi wg1 public key: " PI_WG1_PUBLIC_KEY
read -r -p "Mobile WireGuard public key: " MOBILE_PUBLIC_KEY
read -r -p "NordVPN token: " NORDVPN_TOKEN
read -r -p "Pi Meshnet device name (as shown in nordvpn meshnet peer list): " PI_MESHNET_NAME

apt-get update
apt-get install -y wireguard curl iproute2

# Install NordVPN CLI
curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh

# Login and enable Meshnet
nordvpn login --token "${NORDVPN_TOKEN}"
nordvpn set meshnet on

# Generate keys for wg1 (bootstrap)
umask 077
wg genkey | tee /root/vps_wg1_private.key | wg pubkey > /root/vps_wg1_public.key
VPS_WG1_PRIVATE_KEY=$(cat /root/vps_wg1_private.key)

# Generate keys for wg0 (mobile access)
wg genkey | tee /root/vps_wg0_private.key | wg pubkey > /root/vps_wg0_public.key
VPS_WG0_PRIVATE_KEY=$(cat /root/vps_wg0_private.key)

# Configure wg1
cat > /etc/wireguard/wg1.conf <<CONF
[Interface]
Address = 10.200.0.1/30
ListenPort = 51821
PrivateKey = ${VPS_WG1_PRIVATE_KEY}

[Peer]
PublicKey = ${PI_WG1_PUBLIC_KEY}
AllowedIPs = 10.200.0.2/32
PersistentKeepalive = 25
CONF

# Configure wg0
cat > /etc/wireguard/wg0.conf <<CONF
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = ${VPS_WG0_PRIVATE_KEY}

[Peer]
PublicKey = ${MOBILE_PUBLIC_KEY}
AllowedIPs = 10.100.0.2/32
CONF

systemctl enable --now wg-quick@wg1
systemctl enable --now wg-quick@wg0

# Route via Pi for Meshnet traffic
nordvpn meshnet route add "${PI_MESHNET_NAME}"

# Route watcher for automatic fallback
cat > /usr/local/sbin/meshnet-route-watch.sh <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

CHECK_HOST="downloads.nordcdn.com"
CHECK_PORT=443
WG_IFACE="wg1"
WG_GATEWAY="10.200.0.2"
PUBLIC_GATEWAY="${VPS_PUBLIC_GATEWAY}"

check_reachability() {
  timeout 3 bash -c "</dev/tcp/${CHECK_HOST}/${CHECK_PORT}" >/dev/null 2>&1
}

set_default_public() {
  ip route replace default via "${PUBLIC_GATEWAY}"
}

set_default_wg() {
  ip route replace default via "${WG_GATEWAY}" dev "${WG_IFACE}"
}

while true; do
  if check_reachability; then
    set_default_public
  else
    set_default_wg
  fi
  sleep 15
done
SCRIPT
chmod +x /usr/local/sbin/meshnet-route-watch.sh

cat > /etc/systemd/system/meshnet-route-watch.service <<UNIT
[Unit]
Description=Meshnet route watcher (fallback to Pi when NordVPN blocked)
After=network-online.target wg-quick@wg1.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/meshnet-route-watch.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now meshnet-route-watch.service

cat <<INFO

VPS setup complete.

VPS wg1 public key:
$(cat /root/vps_wg1_public.key)

VPS wg0 public key (for mobile peer config):
$(cat /root/vps_wg0_public.key)

Next:
- Add VPS wg1 public key to Pi wg1 peer.
- Add VPS wg0 public key to mobile WireGuard profile.
INFO
