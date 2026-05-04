output "instance_id" {
  value = aws_instance.sql_server.id
}

output "private_ip" {
  value = aws_instance.sql_server.private_ip
}

output "security_group_id" {
  value = aws_security_group.sql.id
}