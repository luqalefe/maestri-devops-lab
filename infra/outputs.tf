output "api_url" {
  description = "URL base da HTTP API. Use como: curl $api_url/tasks"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "table_name" {
  description = "Nome da tabela DynamoDB usada pela Lambda."
  value       = aws_dynamodb_table.tasks.name
}

output "lambda_function_name" {
  description = "Nome da função Lambda para facilitar invocação e debug manual."
  value       = aws_lambda_function.api.function_name
}
