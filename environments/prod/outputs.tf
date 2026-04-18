output "instance_public_ip" {
  description = "Public IP (elastic) of the production server"
  value       = aws_eip.prod.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/prod-ec2-key ubuntu@${aws_eip.prod.public_ip}"
}