# WireGuard VPN Setup for Dev Environment

## Overview

This sets up a WireGuard VPN on the dev EC2 so the development environment
is only accessible to the team — not the public internet.

```
Teammates  ── encrypted tunnel ──>  Dev EC2 (only VPN port is public)
                                      ├── Nginx (port 80/443)
                                      ├── SSH (port 22)
                                      └── Docker containers
```

## VPN Network Layout

The VPN uses `192.168.100.0/24`. This subnet is intentionally outside the
VPC CIDR (`10.0.0.0/16`) — using `10.0.0.0/24` collides with VPC routing on
the EC2's primary ENI, so handshakes succeed but no traffic flows.

| Who        | VPN IP            |
|------------|-------------------|
| Dev EC2    | 192.168.100.1     |
| teammate1  | 192.168.100.2     |
| teammate2  | 192.168.100.3     |
| teammate3  | 192.168.100.4     |

## Initial Setup (one-time)

### 1. Run the setup script on the dev EC2

```bash
scp scripts/setup-wireguard.sh ubuntu@<DEV_ELASTIC_IP>:~
ssh ubuntu@<DEV_ELASTIC_IP>
chmod +x setup-wireguard.sh
sudo ./setup-wireguard.sh
```

### 2. Update Terraform security groups

Apply the security group changes in your Terraform config. See the
`terraform/` directory for the updated rules. The key change is:

- **Add** UDP 51820 from `0.0.0.0/0` (WireGuard port)
- **Change** TCP 80, 443, 22 from `0.0.0.0/0` to `192.168.100.0/24` (VPN only)

> Both AWS Security Groups **and** the host firewall (UFW on Ubuntu) must
> allow UDP 51820. The setup script opens UFW automatically; if you skip it,
> run `sudo ufw allow 51820/udp && sudo ufw allow in on wg0 && sudo ufw reload`.

Then run:

```bash
cd terraform
terraform plan
terraform apply
```

### 3. Distribute client configs

Each teammate's config is at `/etc/wireguard/clients/<name>.conf` on the
dev EC2. Send these securely (not over Slack/email in plaintext — use
a secure file transfer or an encrypted channel).

```bash
# Copy a teammate's config to your local machine
scp ubuntu@<DEV_ELASTIC_IP>:/etc/wireguard/clients/teammate1.conf .
```

### 4. Teammates connect

1. Install WireGuard: https://www.wireguard.com/install/
   - macOS: App Store
   - Windows: wireguard.com/install
   - Linux: `sudo apt install wireguard`
2. Import the `.conf` file into the WireGuard app
3. Toggle the connection on
4. Access the dev environment at `http://192.168.100.1`
5. SSH: `ssh ubuntu@192.168.100.1`

## Adding a New Teammate

On the dev EC2:

```bash
# Generate keys for the new peer
wg genkey | tee /tmp/new_private.key | wg pubkey > /tmp/new_public.key

# Add peer to the running WireGuard interface
sudo wg set wg0 peer $(cat /tmp/new_public.key) allowed-ips 192.168.100.5/32

# Save the running config so it persists across reboots
sudo wg-quick save wg0

# Create their client config
cat > /tmp/new_teammate.conf <<EOF
[Interface]
PrivateKey = $(cat /tmp/new_private.key)
Address = 192.168.100.5/24
DNS = 1.1.1.1

[Peer]
PublicKey = $(sudo cat /etc/wireguard/server_public.key)
Endpoint = <DEV_ELASTIC_IP>:51820
AllowedIPs = 192.168.100.0/24
PersistentKeepalive = 25
EOF

# Clean up key files
rm /tmp/new_private.key /tmp/new_public.key

# Send /tmp/new_teammate.conf to the new teammate securely
```

## Removing a Teammate

```bash
# Find their public key
sudo wg show wg0

# Remove the peer
sudo wg set wg0 peer <THEIR_PUBLIC_KEY> remove

# Save the running config
sudo wg-quick save wg0
```

## Troubleshooting

```bash
# Check WireGuard status and connected peers
sudo wg show

# Check if the interface is up
ip a show wg0

# Restart WireGuard
sudo systemctl restart wg-quick@wg0

# Check logs
sudo journalctl -u wg-quick@wg0 -f

# Test connectivity from a teammate's machine (after connecting VPN)
ping 192.168.100.1
```

### Common issues

- **No handshake at all** (`sudo wg show` shows no `latest handshake:` line):
  the SG allows UDP 51820 but UFW is dropping it. Run
  `sudo ufw status` — if active without a 51820/udp rule, run
  `sudo ufw allow 51820/udp && sudo ufw allow in on wg0 && sudo ufw reload`.
- **Can't connect**: Make sure the Terraform security group allows UDP 51820
  from `0.0.0.0/0`. Apply Terraform changes BEFORE restricting other ports.
- **Connected but can't reach services**: Check that security group rules
  for TCP 80/443/22 allow `192.168.100.0/24`.
- **Handshake but no traffic**: Check IP forwarding is enabled:
  `sysctl net.ipv4.ip_forward` should return `1`. Also confirm the VPN
  subnet doesn't overlap with the VPC CIDR (`10.0.0.0/16`) — if it does,
  the EC2 routes VPN traffic out the wrong interface.

## CI/CD Access

Your CI/CD pipeline can't use the VPN. Options:

1. **AWS SSM (recommended)**: Deploy via `aws ssm send-command` — no inbound
   port needed, authenticates through IAM.
2. **Self-hosted runner**: Run the CI/CD runner on the EC2 itself.
3. **Allowlist CI IPs**: Open SSH for your CI provider's IP ranges (less secure).

See the main infra README for CI/CD configuration details.