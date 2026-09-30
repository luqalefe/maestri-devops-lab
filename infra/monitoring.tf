# ─── Log group da Lambda ─────────────────────────────────────────────────────

#checkov:skip=CKV_AWS_338: Retenção de 1 ano é desproporcional para um laboratório de um dia; 14 dias cobre debug pós-destroy com custo mínimo.
#checkov:skip=CKV_AWS_158: CMK própria para logs exigiria criar e gerir uma KMS key; o laboratório não tem dado sensível nos logs que justifique esse overhead.
resource "aws_cloudwatch_log_group" "lambda" {
  # O nome /aws/lambda/<nome-da-função> é o padrão esperado pelo runtime do
  # Lambda; qualquer outro nome exigiria configurar o log group manualmente
  # via variável de ambiente, quebrando o fluxo padrão do CloudWatch.
  name = "/aws/lambda/${var.prefix}-api"

  # 14 dias cobre o período do laboratório com folga suficiente para debug
  # pós-destroy, sem acumular custo de armazenamento de logs indefinidamente.
  retention_in_days = 14
}
