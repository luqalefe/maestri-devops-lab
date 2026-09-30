variable "prefix" {
  description = "Prefixo de nomeação dos recursos. Mantém consistência entre os ARNs usados na policy do gha-plan (que prefixam com 'maestri-')."
  type        = string
  default     = "maestri"
}

variable "lambda_memory_mb" {
  description = "Memória alocada para a Lambda em MB. 256 MB é suficiente para CRUD simples com boto3; aumentar se os testes de carga mostrarem latência de cold start acima de 1 s."
  type        = number
  default     = 256
}

variable "lambda_timeout_s" {
  description = "Timeout da Lambda em segundos. 10 s cobre o cold start do Python + chamada ao DynamoDB com retries; acima disso o API Gateway HTTP já teria encerrado a conexão (29 s de limit)."
  type        = number
  default     = 10
}

variable "api_throttle_rate" {
  description = "Limite de requisições por segundo no API Gateway (ADR 2: proteção mínima sem autenticação)."
  type        = number
  default     = 100
}

variable "api_throttle_burst" {
  description = "Burst máximo de requisições simultâneas no API Gateway."
  type        = number
  default     = 200
}
