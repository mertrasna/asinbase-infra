# Key-pair for SSH access into EC2 
resource "aws_key_pair" "dev" {
  key_name   = "dev-ec2-key"
  public_key = file("~/.ssh/dev-ec2-key.pub")
}

# Data block for verified ubuntu 24.04 - exact prod version
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# EC2 instance
resource "aws_instance" "dev" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro" # free tier eligible

  # Network
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true

  # Auth + permissions
  key_name             = aws_key_pair.dev.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_dev.name

  # Disk
  root_block_device {
    volume_size           = 20 # GB
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data                   = file("./user_data.sh") # For boot-time setup
  user_data_replace_on_change = true
}

# Elastic IP - static public IP
resource "aws_eip" "dev" {
  domain   = "vpc"
  instance = aws_instance.dev.id

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "$(local.name_prefix)-web-eip"
  }

  # Make sure the IGW exists before EIP association  
  depends_on = [aws_internet_gateway.main]
}