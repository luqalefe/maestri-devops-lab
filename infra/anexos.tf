# ─── Bucket de anexos das tarefas ─────────────────────────────────────────────

data "aws_caller_identity" "atual" {}

resource "aws_s3_bucket" "anexos" {
  # checkov:skip=CKV_AWS_18: access logging exigiria um segundo bucket só para logs, e o laboratório dura um dia.
  # checkov:skip=CKV_AWS_21: versionamento + lifecycle de 1 dia deixaria versões antigas para trás e complicaria o destroy; o anexo é descartável por desenho.
  # checkov:skip=CKV_AWS_144: replicação entre regiões não faz sentido para dado que expira em 1 dia.
  # checkov:skip=CKV_AWS_145: SSE-S3 (AES256) já criptografa em repouso; CMK própria exigiria kms:* extra no gha-deploy e na Lambda sem ganho para o laboratório.
  # checkov:skip=CKV2_AWS_62: ninguém consome notificação de evento deste bucket.

  # O prefixo "maestri-anexos-" é o que as policies do bootstrap usam para
  # escopo; não dá para chamar de maestri-devops-lab-* porque isso também
  # casaria com o bucket de state. A conta entra no nome porque o namespace
  # de buckets é global.
  bucket = "${var.prefix}-anexos-${data.aws_caller_identity.atual.account_id}"

  # O destroy limpo da seção 7 não pode travar em BucketNotEmpty: o anexo
  # é descartável e expira sozinho, então esvaziar junto é o comportamento certo.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "anexos" {
  bucket = aws_s3_bucket.anexos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "anexos" {
  bucket = aws_s3_bucket.anexos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "anexos" {
  bucket = aws_s3_bucket.anexos.id

  rule {
    id     = "expirar-em-1-dia"
    status = "Enabled"

    # Filtro vazio = a regra vale para o bucket inteiro (o provider 5.x avisa
    # se nem filter nem prefix forem declarados).
    filter {}

    expiration {
      days = 1
    }

    # Upload multipart abandonado também ocupa espaço e não é coberto pela
    # expiração dos objetos.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# A URL pré-assinada é https; negar o resto fecha o caminho de quem tentasse
# usar o bucket sem TLS com as credenciais da Lambda.
data "aws_iam_policy_document" "anexos_tls" {
  statement {
    sid       = "NegarSemTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.anexos.arn, "${aws_s3_bucket.anexos.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "anexos" {
  bucket = aws_s3_bucket.anexos.id
  policy = data.aws_iam_policy_document.anexos_tls.json

  # Policy e public access block mexem na mesma configuração do bucket;
  # aplicadas em paralelo, a AWS responde OperationAborted.
  depends_on = [aws_s3_bucket_public_access_block.anexos]
}
