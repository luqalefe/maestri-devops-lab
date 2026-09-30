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
  alarm_description = "O API Gateway acumulou mais de 10 requisições 4xx em pelo menos um dos últimos 5 minutos. Complementa o alarme de throttle da Lambda: o API GW throttle ocorre ANTES de a Lambda ser invocada, então os dois alarmes cobrem camadas diferentes."
  namespace         = "AWS/ApiGateway"
  metric_name       = "4xx"
  # A métrica de throttle do HTTP API v2 é publicada como 4xx (429 incluído);
  # não existe dimensão "ThrottleCount" separada no HTTP API.
  dimensions = {
    ApiId = aws_apigatewayv2_api.api.id
    Stage = "$default"
  }
  statistic = "Sum"
  period    = 60
  # evaluation_periods=5 com datapoints_to_alarm=1: dispara quando QUALQUER
  # UM dos últimos 5 minutos ultrapassar 10 — captura rajadas mesmo que
  # durem menos de 5 minutos. Sem datapoints_to_alarm, o padrão seria
  # exigir os 5 períodos seguidos, o que deixaria uma rajada de 3 min passar.
  evaluation_periods  = 5
  datapoints_to_alarm = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "apigw_latency_p95" {
  alarm_name        = "${var.prefix}-apigw-latency-p95"
  alarm_description = "Latência p95 ponta a ponta da API acima de 3 s. Com timeout da Lambda em 10 s e cold start esperado de ~1-2 s em Python 3.12, 3 s cobre cold start sem alarmar no warm path; acima disso indica saturação ou regressão."
  namespace         = "AWS/ApiGateway"
  # Latency mede o tempo total do API GW (receber requisição até devolver resposta),
  # que inclui overhead do gateway além do backend. IntegrationLatency mede só
  # o backend (Lambda); o briefing pede a latência da API, então usamos Latency.
  metric_name = "Latency"
  dimensions = {
    ApiId = aws_apigatewayv2_api.api.id
    Stage = "$default"
  }
  # p95 exige extended_statistic, não statistic; os dois são mutuamente exclusivos.
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
