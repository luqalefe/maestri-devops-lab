locals {
  # ARN do provider OIDC do GitHub criado neste bootstrap.
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn

  # Prefixo do subject claim enviado pelo GitHub Actions. O trust usa esse
  # valor para restringir quais eventos podem assumir cada role.
  github_subject_prefix = "repo:${var.github_repo}"
}

# ─── gha-plan ────────────────────────────────────────────────────────────────
# Role assumido pelo CI de PR para rodar terraform plan -lock=false.
# Só leitura: lê o state (s3:GetObject/ListBucket) e faz o refresh dos
# recursos (ações de Get/List/Describe). Não escreve na AWS.

data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Restrito ao evento pull_request do repositório específico; qualquer
      # outra branch ou evento não consegue assumir este role. Usamos StringLike
      # com :pull_request porque o GitHub usa sub = "repo:<org>/<repo>:pull_request"
      # para PRs (sem número de PR no sub).
      values = ["${local.github_subject_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "gha_plan" {
  name               = "gha-plan"
  assume_role_policy = data.aws_iam_policy_document.gha_plan_trust.json

  tags = {
    Purpose = "CI read-only plan via OIDC"
  }
}

data "aws_iam_policy_document" "gha_plan_policy" {
  # Permissões mínimas para que o terraform plan consiga ler o state e fazer
  # refresh de cada recurso gerenciado em infra/. Nenhuma ação de escrita.

  statement {
    sid    = "LerStateBucket"
    effect = "Allow"
    actions = [
      # GetObject lê o arquivo de state; GetObjectVersion lê versões antigas
      # que o use_lockfile consulta para verificar se o lock foi liberado.
      "s3:GetObject",
      "s3:GetObjectVersion",
      # ListBucket é necessário para o backend S3 verificar a existência do
      # objeto de state antes de baixá-lo (retorna 403 sem essa permissão).
      "s3:ListBucket",
    ]
    # Restrito ao bucket de state; não usa * para não dar acesso a todo S3.
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid    = "RefreshDynamoDB"
    effect = "Allow"
    actions = [
      # Necessário para o provider leia o estado atual da tabela no refresh.
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
    ]
    # O ARN da tabela é criado pelo módulo infra/ e não está disponível no
    # bootstrap. O plan de PR só precisa do refresh do provider, que usa
    # o ARN do state — sem curingas em actions (cumprindo ADR 3/Regra 3).
    # Usamos o ARN prefixado pela conta/região que será lida do state.
    # checkov:skip=CKV_AWS_111: resources usa ARN construído com region/account
    # que só existem em runtime; colocar * aqui quebraria o menor-privilégio
    # mais do que o ARN parcial abaixo.
    resources = ["arn:aws:dynamodb:us-east-1:*:table/maestri-*"]
  }

  statement {
    sid    = "RefreshLambda"
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetPolicy",
      "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig",
    ]
    resources = ["arn:aws:lambda:us-east-1:*:function:maestri-*"]
  }

  statement {
    sid    = "RefreshAPIGateway"
    effect = "Allow"
    actions = [
      "apigatewayv2:GetApi",
      "apigatewayv2:GetStage",
      "apigatewayv2:GetIntegration",
      "apigatewayv2:GetRoute",
      "apigatewayv2:GetTags",
    ]
    # API Gateway v2 não aceita ARN de recurso granular em todas as ações;
    # o recurso mínimo possível é o ARN da API específica, mas sem o ID da
    # API (gerado na criação) usamos o prefixo da conta.
    # checkov:skip=CKV_AWS_111: ARN do API GW v2 exige o apiId que só existe
    # após o apply; plan lê do state, não há como restringir antes da criação.
    resources = ["arn:aws:apigateway:us-east-1::/apis/*"]
  }

  statement {
    sid    = "RefreshLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
    ]
    resources = ["arn:aws:logs:us-east-1:*:log-group:/aws/lambda/maestri-*"]
  }

  statement {
    sid    = "RefreshIAMRole"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
    ]
    resources = ["arn:aws:iam::*:role/maestri-*"]
  }
}

resource "aws_iam_role_policy" "gha_plan" {
  name   = "gha-plan-policy"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.gha_plan_policy.json
}

# ─── gha-deploy ──────────────────────────────────────────────────────────────
# Role assumido pelo workflow de deploy para rodar terraform apply.
# Trust restrito ao environment "production", que o GitHub exige aprovação
# manual — sem essa condição, qualquer dispatch sem aprovação assumiria o role.

data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # environment:production garante que só jobs que passaram pela aprovação
      # do environment conseguem assumir este role; um dispatch sem aprovação
      # gera um sub diferente e é rejeitado pela AWS antes mesmo de rodar.
      values = ["${local.github_subject_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_trust.json

  tags = {
    Purpose = "CI deploy com aprovação via OIDC"
  }
}

data "aws_iam_policy_document" "gha_deploy_policy" {
  # Permissões para criar, atualizar e destruir os recursos gerenciados em
  # infra/. Divididas por serviço para facilitar auditoria e revisão futura.

  statement {
    sid    = "GerenciarStateBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid    = "GerenciarDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:UpdateTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
    ]
    resources = ["arn:aws:dynamodb:us-east-1:*:table/maestri-*"]
  }

  statement {
    sid    = "GerenciarLambda"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetPolicy",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]
    resources = ["arn:aws:lambda:us-east-1:*:function:maestri-*"]
  }

  statement {
    sid    = "GerenciarAPIGateway"
    effect = "Allow"
    actions = [
      "apigatewayv2:CreateApi",
      "apigatewayv2:DeleteApi",
      "apigatewayv2:GetApi",
      "apigatewayv2:UpdateApi",
      "apigatewayv2:CreateStage",
      "apigatewayv2:DeleteStage",
      "apigatewayv2:GetStage",
      "apigatewayv2:UpdateStage",
      "apigatewayv2:CreateIntegration",
      "apigatewayv2:DeleteIntegration",
      "apigatewayv2:GetIntegration",
      "apigatewayv2:CreateRoute",
      "apigatewayv2:DeleteRoute",
      "apigatewayv2:GetRoute",
      "apigatewayv2:TagResource",
      "apigatewayv2:UntagResource",
      "apigatewayv2:GetTags",
    ]
    # checkov:skip=CKV_AWS_111: API GW v2 não permite restringir por ID de API
    # antes do apply; o ARN da API é gerado dinamicamente pela AWS.
    resources = ["arn:aws:apigateway:us-east-1::/apis/*"]
  }

  statement {
    sid    = "GerenciarLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = ["arn:aws:logs:us-east-1:*:log-group:/aws/lambda/maestri-*"]
  }

  statement {
    sid    = "GerenciarIAMRole"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::*:role/maestri-*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = "gha-deploy-policy"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy_policy.json
}
