data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Purpose = "Role de execução da Lambda da API de tarefas"
  }
}

data "aws_iam_policy_document" "lambda_exec_policy" {
  statement {
    sid    = "AcessarTabelaTarefas"
    effect = "Allow"
    actions = [
      # Apenas as quatro operações que o handler.py chama; nenhuma ação de
      # criação ou alteração de estrutura da tabela, seguindo menor-privilégio.
      "dynamodb:Scan",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.tasks.arn]
  }

  statement {
    sid    = "EscreverLogs"
    effect = "Allow"
    actions = [
      # CreateLogStream cria o stream do container da Lambda; PutLogEvents
      # escreve as linhas de log. Sem essas permissões os logs não aparecem
      # no CloudWatch e o debug de produção fica cego.
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    # Restrito ao log group criado em monitoring.tf; a Lambda não precisa
    # escrever em outros log groups.
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_exec" {
  name   = "${var.prefix}-lambda-exec-policy"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_policy.json
}
