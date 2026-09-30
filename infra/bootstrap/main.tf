# ─── Bucket de state ────────────────────────────────────────────────────────

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # checkov:skip=CKV_AWS_18: Access logging geraria dependência circular no bootstrap; state não contém dado de negócio.
  # checkov:skip=CKV_AWS_144: Replicação cross-region é desproporcional; laboratório de um dia em us-east-1 apenas.
  # checkov:skip=CKV2_AWS_61: Lifecycle policy apagaria versões antigas que o use_lockfile precisa consultar.
  # checkov:skip=CKV2_AWS_62: Notificações de evento não agregam valor; acesso controlado por IAM.

  # Proteção contra exclusão acidental: o state contém o mapa de toda a
  # infra; perder o bucket sem migração força um reimport completo.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    # Versioning é necessário para o use_lockfile do TF 1.10+: o lock usa
    # um objeto S3 com condição de versão para garantir exclusão mútua.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      # aws:kms usa a chave gerenciada pelo S3 (SSE-S3 KMS); suficiente para
      # um laboratório de um dia sem overhead de criação e gestão de CMK própria.
      sse_algorithm = "aws:kms"
    }
    # Bloqueia fallback para sem-criptografia caso alguém suba um objeto
    # sem especificar o header de criptografia.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  # Quatro flags = quatro caminhos distintos de tornar o bucket público por
  # acidente; bloquear todos evita que policy futura exponha o state.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── OIDC Provider do GitHub ─────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  # O bootstrap é aplicado uma vez pelo humano; se a conta já tiver um OIDC
  # provider para o GitHub, o humano importa antes de aplicar:
  #   terraform import aws_iam_openid_connect_provider.github <arn>
  # Não usamos data source porque o data source falha na primeira aplicação
  # (o provider ainda não existe) e o TF não tem "create_if_absent".
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    # "sts.amazonaws.com" é o audience que o aws-actions/configure-aws-credentials
    # envia por padrão; usar outro audience forçaria configuração extra no workflow.
    "sts.amazonaws.com",
  ]

  # Thumbprint da CA raiz do endpoint OIDC do GitHub (publicado em
  # https://github.blog/changelog/2023-06-27-github-actions-oidc-thumbprint).
  # A AWS usa esse valor para validar o certificado TLS do token; sem ele o
  # provider rejeitaria tokens do GitHub em silêncio.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}
