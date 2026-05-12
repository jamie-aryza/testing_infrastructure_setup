output "instance_id" {
  value = aws_instance.sql_server.id
}

output "private_ip" {
  value = aws_instance.sql_server.private_ip
}

output "public_ip" {
  value = aws_instance.sql_server.public_ip
}

output "public_dns" {
  value = aws_instance.sql_server.public_dns
}

output "security_group_id" {
  value = aws_security_group.sql.id
}
