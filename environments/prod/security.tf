resource "aws_security_group" "web" {
  name        = "prod-web-sg"
  description = "Prod EC2: SSH from developers and Github workflows, HTTP/HTTPS from anywhere"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

# Security group for the Application Load Balancer
resource "aws_security_group" "alb" {
  name        = "prod-alb-sg"
  description = "Prod ALB: HTTP/HTTPS from anywhere"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# Ingress rule
resource "aws_vpc_security_group_ingress_rule" "ssh_public" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "tcp"
  description       = "SSH from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22

  lifecycle {
    create_before_destroy = true
  }
}

# will redirect to HTTPS at the listener  
resource "aws_vpc_security_group_ingress_rule" "alb_http_public" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_public" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
}

# Allow traffic from the ALB to reach the EC2 on port 80
resource "aws_vpc_security_group_ingress_rule" "http_from_alb" {
  security_group_id            = aws_security_group.web.id
  ip_protocol                  = "tcp"
  description                  = "HTTP from ALB only"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

# Egress rule
resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "-1" # -1 means any protocol
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
}