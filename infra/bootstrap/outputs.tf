output "state_bucket_name" {
  description = "Nome do bucket S3 usado como backend do Terraform."
  value       = aws_s3_bucket.state.bucket
}

output "gha_plan_role_arn" {
  description = "ARN do role assumido pelo CI de PR para rodar terraform plan."
  value       = aws_iam_role.gha_plan.arn
}

output "gha_deploy_role_arn" {
  description = "ARN do role assumido pelo workflow de deploy para rodar terraform apply."
  value       = aws_iam_role.gha_deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN do OIDC provider do GitHub registrado na conta AWS."
  value       = aws_iam_openid_connect_provider.github.arn
}
