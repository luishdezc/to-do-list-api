output "public_ip" {
  value = aws_instance.app.public_ip
}

output "instance_id" {
  value = aws_instance.app.id
}

output "api_url" {
  value = "http://${aws_instance.app.public_ip}:${var.app_port}/tasks"
}

output "version_url" {
  value = "http://${aws_instance.app.public_ip}:${var.app_port}/version"
}

output "health_url" {
  value = "http://${aws_instance.app.public_ip}:${var.app_port}/health"
}

output "ssh" {
  value = "ssh -i ~/.ssh/todo-list-key ec2-user@${aws_instance.app.public_ip}"
}

output "db_endpoint" {
  value = aws_db_instance.todo.address
}

output "db_identifier" {
  value = aws_db_instance.todo.identifier
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  value = keys(aws_cloudwatch_metric_alarm.this)
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.todo.dashboard_name}"
}
