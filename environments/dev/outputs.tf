output "instance_public_ip" {
  description = "Public IP (elastic) of the development server"
  value       = aws_eip.dev.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/dev-ec2-key ubuntu@${aws_eip.dev.public_ip}"
}