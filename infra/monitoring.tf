# ─── Log group da Lambda ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  # checkov:skip=CKV_AWS_338: Retenção de 1 ano é desproporcional para um laboratório de um dia; 14 dias cobre debug pós-destroy com custo mínimo.
  # checkov:skip=CKV_AWS_158: CMK própria para logs exigiria criar e gerir uma KMS key; o laboratório não tem dado sensível nos logs que justifique esse overhead.

  # O nome /aws/lambda/<nome-da-função> é o padrão esperado pelo runtime do
  # Lambda; qualquer outro nome exigiria configurar o log group manualmente
  # via variável de ambiente, quebrando o fluxo padrão do CloudWatch.
  name = "/aws/lambda/${var.prefix}-api"

  # 14 dias cobre o período do laboratório com folga suficiente para debug
  # pós-destroy, sem acumular custo de armazenamento de logs indefinidamente.
  retention_in_days = 14
}

# ─── Alarmes CloudWatch ───────────────────────────────────────────────────────
#
# Nenhum alarme tem alarm_actions / ok_actions porque o laboratório dura um dia
# e um tópico SNS extra é recurso a mais para o destroy esquecer. O alarme sem
# destino ainda é útil: fica em ALARM no console e é consultável via API/CLI
# durante o smoke test e a investigação pós-evento.

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name        = "${var.prefix}-lambda-errors"
  alarm_description = "A Lambda retornou pelo menos um erro (exceção não capturada ou timeout) nos últimos 5 minutos. Qualquer erro em produção real merece investigação; aqui serve para detectar regressão no smoke test."
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions        = { FunctionName = aws_lambda_function.api.function_name }
  statistic         = "Sum"
  # 5 min é o período mínimo que o CloudWatch publica para métricas Lambda
  # de alta resolução; 1 evaluation_period evita atraso desnecessário numa
  # janela de laboratório curta.
  period             = 300
  evaluation_periods = 1
  # Limiar 0 com comparison GreaterThanThreshold dispara com qualquer erro;
  # mais agressivo do que seria num serviço de produção com tráfego real, mas
  # correto para detectar falha em smoke test (1 requisição com título inválido).
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name         = "${var.prefix}-lambda-throttles"
  alarm_description  = "A Lambda foi throttled pelo menos uma vez nos últimos 5 minutos. Com concurrency limit ausente (skip justificado), throttle aqui significa que a conta atingiu o limite regional de concorrência — sinal de custo inesperado ou abuso."
  namespace          = "AWS/Lambda"
  metric_name        = "Throttles"
  dimensions         = { FunctionName = aws_lambda_function.api.function_name }
  statistic          = "Sum"
  period             = 300
  evaluation_periods = 1
  # Qualquer throttle num laboratório indica problema de configuração ou abuso;
  # não há tráfego legítimo suficiente para throttle acidental.
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "apigw_throttles" {
  alarm_name        = "${var.prefix}-apigw-throttles"
  alarm_description = "O API Gateway descartou requisições por throttle no stage $default. Complementa o alarme de throttle da Lambda: o API GW throttle ocorre ANTES de a Lambda ser invocada, então os dois alarmes cobrem camadas diferentes."
  namespace         = "AWS/ApiGateway"
  metric_name       = "4xx"
  # A métrica de throttle do HTTP API v2 é publicada por ApiId+Stage;
  # não existe dimensão "ThrottleCount" separada no HTTP API — 429s aparecem
  # como 4xx com o filtro de status_code=429. Usar 4xx total é mais conservador
  # (aciona com qualquer erro de cliente, não só throttle), mas para o
  # laboratório isso é preferível a não ter cobertura de throttle no API GW.
  dimensions = {
    ApiId = aws_apigatewayv2_api.api.id
    Stage = "$default"
  }
  statistic = "Sum"
  # 1 min captura picos de throttle com mais granularidade; o API GW publica
  # métricas de 1 min por padrão, diferente da Lambda que usa 1 min também
  # mas aqui queremos resposta rápida para abuso (ADR 2: API pública).
  period             = 60
  evaluation_periods = 5
  # Limiar 10 em 5 min (5 × 60 s): tolera erros de cliente legítimos (400)
  # sem acionar a cada requisição malformada isolada, mas detecta padrão
  # de throttle ou ataque de scanning.
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "apigw_latency_p95" {
  alarm_name        = "${var.prefix}-apigw-latency-p95"
  alarm_description = "Latência p95 da API acima de 3 s nos últimos 5 minutos. Com timeout da Lambda em 10 s e cold start esperado de ~1-2 s em Python 3.12, 3 s cobre cold start sem alarmar no warm path; acima disso indica saturação ou regressão."
  namespace         = "AWS/ApiGateway"
  metric_name       = "IntegrationLatency"
  dimensions = {
    ApiId = aws_apigatewayv2_api.api.id
    Stage = "$default"
  }
  # p95 exige extended_statistic, não statistic; os dois são mutuamente exclusivos.
  extended_statistic = "p95"
  period             = 300
  evaluation_periods = 1
  # 3000 ms = 3 s: cobre cold start (~1-2 s) + roundtrip DynamoDB (~5-10 ms
  # em us-east-1 on-demand) com folga; abaixo de 3 s seria muito ruidoso
  # num laboratório sem tráfego aquecido.
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
