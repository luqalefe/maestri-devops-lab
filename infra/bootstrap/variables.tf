variable "github_repo" {
  description = "Repositório no formato <org>/<repo> usado nos trusts OIDC. Entra por variável porque o repo ainda não existe quando o bootstrap é aplicado pela primeira vez."
  type        = string
}

variable "state_bucket_name" {
  description = "Nome único do bucket S3 que guardará o state do Terraform. Nomes de bucket são globais; o humano escolhe antes de aplicar."
  type        = string
}
