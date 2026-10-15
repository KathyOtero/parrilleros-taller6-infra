resource "aws_cloudwatch_metric_alarm" "errores_empleados" {
  alarm_name          = "system errors"
  alarm_description   = "Errores del servicio DynamoDB"
  namespace           = "AWS/DynamoDB"
  metric_name         = "SystemErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.name.name
  }
}

resource "aws_cloudwatch_metric_alarm" "throttling_empleados" {
  alarm_name          = "throttling"
  alarm_description   = "Solicitudes limitadas por capacidad"
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.name.name
  }
}