output "sql_live_public_ip" {
  value = module.sql_live.public_ip
}

output "sql_live_public_dns" {
  value = module.sql_live.public_dns
}

output "sql_test_public_ip" {
  value = module.sql_test.public_ip
}

output "sql_test_public_dns" {
  value = module.sql_test.public_dns
}
