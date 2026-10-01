# ─── DynamoDB ────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "tasks" {
  # checkov:skip=CKV_AWS_119: CMK própria exigiria criar e gerir uma KMS key antes do apply; a chave gerenciada pelo DynamoDB (AWS_OWNED_CMK) cobre o laboratório de um dia sem custo ou dependência extra.

  name         = "${var.prefix}-tasks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    # String é o tipo da chave no handler.py (uuid4 como string); mudar para
    # Number exigiria alteração no código da Lambda sem ganho para o caso de uso.
    type = "S"
  }

  # PITR permite restaurar a tabela para qualquer segundo dos últimos 35 dias;
  # custo zero quando a tabela está vazia, e o laboratório dura um dia.
  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
    # AWS_OWNED_CMK (enabled=true sem kms_key_arn) usa chave gerenciada pelo
    # DynamoDB; suficiente para laboratório de um dia sem overhead de CMK própria.
  }

  # deletion_protection_enabled = false (padrão): o destroy limpo da seção 7
  # precisa apagar a tabela sem intervenção manual.
}

# ─── Empacotamento da Lambda ──────────────────────────────────────────────────

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../app/handler.py"
  output_path = "${path.module}/../app/handler.zip"
}

# ─── Lambda ──────────────────────────────────────────────────────────────────

resource "aws_lambda_function" "api" {
  # checkov:skip=CKV_AWS_50: X-Ray tracing aumenta custo e complexidade; para o laboratório de um dia o CloudWatch Logs cobre o debug necessário.
  # checkov:skip=CKV_AWS_117: VPC exigiria NAT Gateway (proibido pelo ADR/Regra 4) para a Lambda alcançar DynamoDB; a API pública não tem dado sensível justificando o custo.
  # checkov:skip=CKV_AWS_116: DLQ faz sentido para Lambda assíncrona; esta é síncrona (invocada pelo API GW) e erros são retornados diretamente ao cliente como 5xx.
  # checkov:skip=CKV_AWS_173: TABLE_NAME é apenas o nome de um recurso AWS, não um segredo; criptografar variável de ambiente sem CMK não acrescenta proteção real.
  # checkov:skip=CKV_AWS_272: Code-signing exigiria AWS Signer e pipeline extra; o código vem do repositório com controle de acesso via OIDC, o que é controle equivalente para o laboratório.
  # checkov:skip=CKV_AWS_115: Concurrency limit reservado bloqueia capacidade global da conta; sem carga real num laboratório de um dia o throttling do API GW é suficiente.

  function_name    = "${var.prefix}-api"
  description      = "Lambda da API de tarefas — roteamento via routeKey do API Gateway HTTP API."
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.12"
  # handler.handler é o módulo handler.py com a função handler() — alinhado
  # com o contrato definido no brief da T2 e com o que os testes esperam.
  handler = "handler.handler"
  role    = aws_iam_role.lambda_exec.arn
  timeout = var.lambda_timeout_s
  # 256 MB é suficiente para o Python 3.12 com boto3 no cold start; abaixo
  # de 128 MB a AWS não garante CPU suficiente para inicializar o runtime.
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      # A Lambda acessa a tabela pelo nome, não pelo ARN, porque o SDK boto3
      # resolve o endpoint automaticamente pela região do ambiente.
      TABLE_NAME = aws_dynamodb_table.tasks.name
      # Mesmo critério da tabela: nome, não ARN, é o que o boto3 precisa.
      BUCKET_ANEXOS = aws_s3_bucket.anexos.bucket
    }
  }

  # O log group é criado explicitamente em monitoring.tf com retenção de 14
  # dias; sem depends_on, a Lambda criaria o log group sem retenção e o
  # resource de log group daria erro de "já existe".
  depends_on = [aws_cloudwatch_log_group.lambda]
}

# ─── API Gateway HTTP API ─────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "api" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
  description   = "HTTP API para a API de tarefas (ADR 1: HTTP API em vez de REST API — mais barato e suficiente para o CRUD simples)."

  # CORS permissivo porque a API é pública por decisão (ADR 2); sem CORS
  # o frontend de qualquer origem não conseguiria chamar a API do browser.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "DELETE", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.api.invoke_arn
  integration_method = "POST"

  # payload_format_version 2.0 habilita o routeKey no evento recebido pela
  # Lambda; o handler.py depende de event["routeKey"] para rotear as chamadas.
  payload_format_version = "2.0"
}

# Seis rotas explícitas em vez de $default: o handler.py roteia por
# event["routeKey"] com os valores exatos "GET /tasks", "POST /tasks" etc.
# Com $default o API GW enviaria routeKey="$default" e todo request viraria 404.
resource "aws_apigatewayv2_route" "list_tasks" {
  # checkov:skip=CKV_AWS_309: API pública por decisão (ADR 2); sem autenticação por design — o throttling é a única proteção intencional para o laboratório de um dia.
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /tasks"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "create_task" {
  # checkov:skip=CKV_AWS_309: idem — API pública, ADR 2.
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /tasks"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "get_task" {
  # checkov:skip=CKV_AWS_309: idem — API pública, ADR 2.
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /tasks/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "delete_task" {
  # checkov:skip=CKV_AWS_309: idem — API pública, ADR 2.
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "DELETE /tasks/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Rota no handler sem rota aqui = API responde 404 com a suíte verde (foi o
# que aconteceu na rodada 1); test_rotas_do_handler_existem_no_terraform
# compara as duas listas.
resource "aws_apigatewayv2_route" "upload_anexo" {
  # checkov:skip=CKV_AWS_309: idem — API pública, ADR 2.
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /tasks/{id}/anexo"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "download_anexo" {
  # checkov:skip=CKV_AWS_309: idem — API pública, ADR 2.
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /tasks/{id}/anexo"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  # checkov:skip=CKV_AWS_76: Access logging do API GW gera um segundo log group e exige permissão extra; o log da Lambda já cobre o debug para o laboratório de um dia.

  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    # Throttling é a única proteção da API pública (ADR 2); sem ele qualquer
    # cliente pode esgotar a concorrência da Lambda e elevar o custo.
    throttling_rate_limit  = var.api_throttle_rate
    throttling_burst_limit = var.api_throttle_burst
  }
}

# Permissão para o API Gateway invocar a Lambda; sem ela a integração
# retorna 500 (Forbidden) mesmo com a policy da Lambda correta.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
