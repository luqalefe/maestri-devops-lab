variable "github_immutable_subject_prefix" {
  description = "Prefixo do subject OIDC imutável emitido pelo GitHub: repo:<org>@<org-id>/<repo>@<repo-id>. Obtido via: gh api repos/<org>/<repo>/actions/oidc/customization/sub. O subject imutável vincula os trusts aos IDs internos da organização e do repositório — um repo apagado e recriado com o mesmo nome não consegue assumir os roles (ADR 8)."
  type        = string
}

variable "state_bucket_name" {
  description = "Nome único do bucket S3 que guardará o state do Terraform. Nomes de bucket são globais; o humano escolhe antes de aplicar."
  type        = string
}
