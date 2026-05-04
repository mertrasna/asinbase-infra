# Security Group (Ingress & Egress)
# Security Groups are stateful. Meaning if you allow inbound traffic on port 443, the response traffic is automatically allowed back out.
# There is no "deny" rule. Everything not explicitly allowed is denied. You only write "allow" rules.
resource "aws_security_group" "web" {
  name        = "dev-web-sg"
  description = "Dev EC2: SSH from developers, HTTP/HTTPS from anywhere"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

# Ingress rule
resource "aws_vpc_security_group_ingress_rule" "ssh_public" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  description       = "SSH from VPN"
  cidr_ipv4         = "10.0.0.0/24"
  from_port         = 22
  to_port           = 22

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "wireguard_vpn" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "udp"
  description       = "Wireguard vpn connection for securing development environment"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 51820
  to_port           = 51820
}

resource "aws_vpc_security_group_ingress_rule" "http_public" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  description       = "HTTP from VPN"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "10.0.0.0/24"
}

resource "aws_vpc_security_group_ingress_rule" "https_public" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  description       = "HTTPS from VPN"
  cidr_ipv4         = "10.0.0.0/24"
  from_port         = 443
  to_port           = 443
}

# Egress rule
resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "-1" # -1 means any protocol
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
}