terraform {
  # Versão mínima alinhada com o runtime da máquina (1.16.4) e com os
  # workflows da T4, que também usam >= 1.10; use_lockfile só existe a
  # partir do 1.10 e substitui a tabela de lock do DynamoDB.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "maestri-devops-lab"
      Owner     = "lucas"
      ManagedBy = "terraform"
    }
  }
}
