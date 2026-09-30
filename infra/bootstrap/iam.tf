locals {
  # ARN do provider OIDC do GitHub criado neste bootstrap.
  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn

  # ADR 8: o GitHub emite o subject com os IDs imutáveis da organização e do
  # repositório (ex.: repo:luqalefe@105518587/maestri-devops-lab@1398582099).
  # Usar o nome curto (repo:<org>/<repo>) deixaria os trusts assumíveis por
  # qualquer repositório recriado com o mesmo nome após exclusão — o prefixo
  # imutável fecha esse risco porque vincula o trust aos IDs, não aos nomes.
  github_subject_prefix = var.github_immutable_subject_prefix

  # ARN da policy da Lambda usada no gha-deploy para fechar o escalonamento
  # (ADR 10): só essa policy pode ser anexada por AttachRolePolicy; qualquer
  # tentativa de anexar AdministratorAccess ou outra policy é negada pela
  # condição iam:PolicyARN mesmo que o chamador tenha iam:AttachRolePolicy.
  lambda_basic_execution_policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─── gha-plan ────────────────────────────────────────────────────────────────
# Role assumido pelo CI de PR e pelo job plan do deploy para rodar plan -lock=false.
# Só leitura: lê o state e faz refresh. Não escreve nada na AWS.

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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # ADR 7: dois subjects — pull_request para o CI de PR e ref:refs/heads/main
      # para o job plan do deploy (que roda sem environment, antes da aprovação).
      # ADR 8: usamos o prefixo imutável; ver local.github_subject_prefix.
      # StringEquals (não StringLike) fecha qualquer outro evento ou branch.
      values = [
        "${local.github_subject_prefix}:pull_request",
        "${local.github_subject_prefix}:ref:refs/heads/main",
      ]
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
  # Permissões mínimas para que o terraform plan leia o state e faça refresh
  # de cada recurso em infra/. Nenhuma ação de escrita.

  statement {
    sid    = "LerStateBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      # ListBucket é necessário para o backend S3 verificar a existência do
      # objeto de state antes de baixá-lo (retorna 403 sem essa permissão).
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid    = "RefreshDynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
    ]
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
      # O serviço IAM correto para HTTP API v2 é "apigateway" (não "apigatewayv2");
      # o Terraform usa a API REST do plano de controle da AWS, que vive em
      # apigateway:GET/POST/PATCH/DELETE independente do protocolo da API criada.
      "apigateway:GET",
    ]
    # checkov:skip=CKV_AWS_111: o ARN do API GW inclui o apiId gerado na criação;
    # no plan/refresh de PR o ID ainda não é conhecido — usamos o prefixo da conta.
    resources = ["arn:aws:apigateway:us-east-1::*"]
  }

  statement {
    sid    = "RefreshLogsArn"
    effect = "Allow"
    actions = [
      "logs:ListTagsForResource",
    ]
    resources = ["arn:aws:logs:us-east-1:*:log-group:/aws/lambda/maestri-*"]
  }

  statement {
    sid    = "DescribeLogGroupsGlobal"
    effect = "Allow"
    actions = [
      # logs:DescribeLogGroups não aceita ARN de recurso específico: a AWS
      # ignora o ARN e retorna 403 ou lista vazia. Só funciona com resource "*".
      # O provider usa essa ação no refresh do log group, então é necessária.
      "logs:DescribeLogGroups",
    ]
    # checkov:skip=CKV_AWS_111: DescribeLogGroups só funciona com "*" por design
    # da API do CloudWatch Logs — a AWS não aceita ARN de log group nessa ação.
    resources = ["*"]
  }

  statement {
    sid    = "RefreshCloudWatch"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:us-east-1:*:alarm:maestri-*"]
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
# Trust restrito ao environment "production" (subject imutável, ADR 8).

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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # ADR 8: prefixo imutável garante que o trust não é assumível por um
      # repositório recriado com o mesmo nome depois de excluído.
      # environment:production força aprovação manual antes do apply (ADR 3).
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
      # O serviço IAM correto para HTTP API v2 é "apigateway" (plano de controle
      # unificado da AWS). O Terraform usa GET/POST/PATCH/DELETE nesse serviço;
      # "apigatewayv2" não é um serviço IAM válido — o Access Analyzer devolve
      # INVALID_SERVICE_IN_ACTION para qualquer ação com esse prefixo.
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:PUT",
    ]
    # checkov:skip=CKV_AWS_111: o ARN inclui o apiId gerado na criação; antes
    # do primeiro apply não é possível restringir mais do que o prefixo abaixo.
    resources = ["arn:aws:apigateway:us-east-1::*"]
  }

  statement {
    sid    = "GerenciarLogsArn"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = ["arn:aws:logs:us-east-1:*:log-group:/aws/lambda/maestri-*"]
  }

  statement {
    sid    = "DescribeLogGroupsGlobal"
    effect = "Allow"
    actions = [
      # logs:DescribeLogGroups não aceita ARN de recurso específico: a AWS
      # ignora o ARN e retorna 403 ou lista vazia. Só funciona com resource "*".
      "logs:DescribeLogGroups",
    ]
    # checkov:skip=CKV_AWS_111: DescribeLogGroups só funciona com "*" por design
    # da API do CloudWatch Logs — a AWS não aceita ARN de log group nessa ação.
    resources = ["*"]
  }

  statement {
    sid    = "GerenciarCloudWatch"
    effect = "Allow"
    actions = [
      # Necessário para criar/destruir os quatro alarmes em monitoring.tf.
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = ["arn:aws:cloudwatch:us-east-1:*:alarm:maestri-*"]
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
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::*:role/maestri-*"]
  }

  statement {
    sid    = "AnexarPolicyPermitida"
    effect = "Allow"
    actions = [
      # ADR 10: a condição iam:PolicyARN restringe AttachRolePolicy a uma lista
      # explícita de policies gerenciadas. Sem ela, o gha-deploy consegue criar
      # role/maestri-x com AdministratorAccess e ligar numa Lambda, tornando-se
      # admin da conta — caminho provado pelo Revisor (simulate aprovou antes
      # desta correção). A lista contém só a policy mínima usada pela infra.
      "iam:AttachRolePolicy",
    ]
    resources = ["arn:aws:iam::*:role/maestri-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [local.lambda_basic_execution_policy_arn]
    }
  }

  statement {
    sid    = "PassRoleLambda"
    effect = "Allow"
    actions = [
      # ADR 10: a condição iam:PassedToService restringe PassRole a Lambda.
      # Sem ela, o gha-deploy pode ligar um role de admin em outra Lambda
      # ou serviço e executar código como admin.
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::*:role/maestri-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = "gha-deploy-policy"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy_policy.json
}
