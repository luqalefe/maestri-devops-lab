terraform {
  backend "s3" {
    # O nome do bucket vem por -backend-config na linha de comando porque
    # ele é criado pelo bootstrap e não é conhecido em tempo de código;
    # os workflows da T4 passam TF_STATE_BUCKET como variável de repositório.
    # Exemplo de uso:
    #   terraform init -backend-config="bucket=<nome-do-bucket>"

    key    = "infra/terraform.tfstate"
    region = "us-east-1"

    # use_lockfile usa objetos S3 com condições de versão para exclusão mútua,
    # eliminando a necessidade de uma tabela DynamoDB separada só para lock.
    # Disponível a partir do Terraform 1.10 (ADR 4).
    use_lockfile = true
  }
}
