#!/bin/bash
# =============================================================================
# WireGuard VPN Setup Script for Dev EC2
# =============================================================================
# Usage:
#   1. Copy to dev EC2:  scp setup-wireguard.sh ubuntu@<dev-ec2-ip>:~
#   2. Run on dev EC2:   chmod +x setup-wireguard.sh && sudo ./setup-wireguard.sh
#
# After running this script:
#   - Distribute the generated client configs from /etc/wireguard/clients/
#   - Each teammate imports their .conf file into the WireGuard app
#   - Update your Terraform security groups (see README.md)
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
WG_INTERFACE="wg0"
WG_PORT=51820
# Use 192.168.100.0/24 — must not overlap with the VPC CIDR (10.0.0.0/16),
# otherwise the EC2 routes VPN traffic out its primary ENI instead of wg0.
WG_NETWORK="192.168.100"
SERVER_IP="${WG_NETWORK}.1/24"

# Teammates - add or remove as needed
PEERS=("teammate1" "teammate2" "teammate3")
# Each peer gets: 10.0.0.2, 10.0.0.3, 10.0.0.4, ...

# --- Preflight checks --------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this script as root (sudo ./setup-wireguard.sh)"
  exit 1
fi

# --- Get server public IP ----------------------------------------------------
SERVER_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  # Fallback if metadata service is unavailable
  SERVER_PUBLIC_IP=$(curl -s https://api.ipify.org)
fi
echo "Server public IP: $SERVER_PUBLIC_IP"

# --- Install WireGuard -------------------------------------------------------
echo "Installing WireGuard..."
apt-get update -y
apt-get install -y wireguard qrencode

# --- Generate server keys -----------------------------------------------------
echo "Generating server keys..."
mkdir -p /etc/wireguard/clients
chmod 700 /etc/wireguard

wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIVATE_KEY=$(cat /etc/wireguard/server_private.key)
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)

# --- Detect main network interface -------------------------------------------
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
echo "Main network interface: $MAIN_INTERFACE"

# --- Build server config ------------------------------------------------------
echo "Building server config..."

cat > /etc/wireguard/${WG_INTERFACE}.conf <<EOF
[Interface]
Address = ${SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

# Allow forwarding traffic between VPN clients and the server
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
EOF

# --- Generate peer configs ----------------------------------------------------
echo "Generating peer configs..."

PEER_INDEX=2
for PEER_NAME in "${PEERS[@]}"; do
  PEER_IP="${WG_NETWORK}.${PEER_INDEX}/32"
  PEER_IP_WITH_SUBNET="${WG_NETWORK}.${PEER_INDEX}/24"

  # Generate peer keys
  PEER_PRIVATE_KEY=$(wg genkey)
  PEER_PUBLIC_KEY=$(echo "$PEER_PRIVATE_KEY" | wg pubkey)

  # Add peer to server config
  cat >> /etc/wireguard/${WG_INTERFACE}.conf <<EOF

# ${PEER_NAME}
[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
AllowedIPs = ${PEER_IP}
EOF

  # Create client config file
  cat > /etc/wireguard/clients/${PEER_NAME}.conf <<EOF
[Interface]
PrivateKey = ${PEER_PRIVATE_KEY}
Address = ${PEER_IP_WITH_SUBNET}
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${WG_NETWORK}.0/24
PersistentKeepalive = 25
EOF

  # Generate QR code for mobile setup
  qrencode -t ansiutf8 < /etc/wireguard/clients/${PEER_NAME}.conf > /etc/wireguard/clients/${PEER_NAME}.qr.txt

  echo "  Created config for ${PEER_NAME} (${PEER_IP})"
  PEER_INDEX=$((PEER_INDEX + 1))
done

chmod 600 /etc/wireguard/clients/*

# --- Enable IP forwarding ----------------------------------------------------
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf

# --- Open UFW for WireGuard --------------------------------------------------
# UFW is active by default on Ubuntu and silently drops UDP 51820 even when
# the AWS Security Group allows it — both layers must permit the traffic.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "Opening UFW for WireGuard..."
  ufw allow ${WG_PORT}/udp comment 'WireGuard'
  ufw allow in on ${WG_INTERFACE}
  ufw reload
fi

# --- Start WireGuard ---------------------------------------------------------
echo "Starting WireGuard..."
systemctl enable wg-quick@${WG_INTERFACE}
systemctl start wg-quick@${WG_INTERFACE}

# --- Print summary ------------------------------------------------------------
echo ""
echo "============================================================================="
echo "  WireGuard VPN setup complete!"
echo "============================================================================="
echo ""
echo "  Server VPN IP:   ${WG_NETWORK}.1"
echo "  VPN Port:        ${WG_PORT}/UDP"
echo ""
echo "  Client configs are in: /etc/wireguard/clients/"
echo ""
for i in "${!PEERS[@]}"; do
  echo "    ${PEERS[$i]}: ${WG_NETWORK}.$((i+2))  ->  /etc/wireguard/clients/${PEERS[$i]}.conf"
done
echo ""
echo "  Next steps:"
echo "    1. Send each teammate their .conf file (use a secure channel!)"
echo "    2. Teammates install WireGuard app and import the .conf"
echo "    3. Update your Terraform security groups:"
echo "       - Add:    UDP ${WG_PORT} from 0.0.0.0/0"
echo "       - Change: TCP 80, 443, 22 from 0.0.0.0/0 -> ${WG_NETWORK}.0/24"
echo "    NOTE: ${WG_NETWORK}.0/24 is intentionally outside the VPC CIDR (10.0.0.0/16)"
echo "          to avoid routing collisions on the EC2's primary ENI."
echo "    4. Apply Terraform changes"
echo "    5. Teammates connect VPN, then access dev at http://${WG_NETWORK}.1"
echo ""
echo "  Useful commands:"
echo "    sudo wg show                          # Check connected peers"
echo "    sudo systemctl restart wg-quick@wg0   # Restart VPN"
echo "    sudo cat /etc/wireguard/clients/<name>.conf  # View a client config"
echo "============================================================================="