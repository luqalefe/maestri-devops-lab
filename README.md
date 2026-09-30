# maestri-devops-lab

Laboratório descartável do andar **DevOps** do Maestri: uma API de tarefas (to-do)
serverless na AWS, construída do repositório vazio até o deploy validado e o
`destroy`, com agentes de IA escrevendo e revisando cada etapa. O produto é
pretexto; o que se mede é o caminho — Terraform, CI, deploy com aprovação e
limpeza no fim. Nasce e morre no mesmo dia.

> A API é **pública de propósito** (sem autenticação, só throttling) porque vive
> só durante a rodada e não guarda dado real. Não reaproveite isto como está em
> produção.

## Arquitetura

Um HTTP API Gateway (`us-east-1`) recebe todas as rotas (`$default`) e as entrega
a uma Lambda Python 3.12, que roteia por `routeKey` e lê/grava numa tabela
DynamoDB on-demand (chave `id`, PITR e criptografia ligados). A Lambda tem um
role próprio com acesso só a essa tabela e ao seu log group (retenção de 14
dias). O state do Terraform fica num bucket S3 com lock nativo
(`use_lockfile`), e o GitHub Actions fala com a AWS por OIDC, sem nenhuma chave
estática.

Rotas: `GET /tasks` (paginada: `?limit=1..100`, `?cursor=`), `POST /tasks`,
`GET /tasks/{id}`, `DELETE /tasks/{id}`.

```
app/            Lambda (handler.py) e testes (pytest + moto)
infra/          Terraform da aplicação (tabela, Lambda, API, IAM, logs)
infra/bootstrap/  bucket de state + provider OIDC + roles gha-plan e gha-deploy
.github/workflows/  ci.yml (PR) e deploy.yml (manual)
```

Briefing, regras, ADRs e diário do experimento: `~/code/partituras/notas/devops-agora.md`
(fonte de verdade, fora deste repositório).

## Rodar os testes

```sh
python3 -m venv .venv
.venv/bin/pip install -r app/requirements.txt -r app/requirements-dev.txt
.venv/bin/python -m pytest app/tests -q
```

A suíte usa `moto`: não fala com a AWS e não precisa de credencial. O CI roda em
Python 3.12, o mesmo runtime da Lambda.

## Aplicar (feito à mão, por uma pessoa)

Nenhum agente e nenhum workflow roda o `apply` do bootstrap. Requer Terraform
`1.16.4` (a mesma versão fixada nos workflows, ADR 6) e credenciais AWS de
administrador na sua máquina.

**1. Bootstrap** (uma vez; o state dele é local, em `infra/bootstrap/terraform.tfstate`,
ignorado pelo git — não o perca enquanto o bootstrap existir):

```sh
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply \
  -var github_repo=luqalefe/maestri-devops-lab \
  -var state_bucket_name=maestri-devops-lab-tfstate-813875215626
```

Cria o bucket `maestri-devops-lab-tfstate-813875215626`, o OIDC provider do GitHub
e os roles `gha-plan` e `gha-deploy`.

**2. Infra**, com o state no bucket:

```sh
terraform -chdir=infra init -backend-config="bucket=maestri-devops-lab-tfstate-813875215626"
terraform -chdir=infra plan
terraform -chdir=infra apply
```

**3. Smoke test:**

```sh
API=$(terraform -chdir=infra output -raw api_url)
curl -s -X POST "$API/tasks" -H 'content-type: application/json' -d '{"title":"teste"}'
curl -s "$API/tasks"
curl -s -X POST "$API/tasks" -d '{}' -o /dev/null -w '%{http_code}\n'   # espera 400
```

## CI e deploy

Configuração no GitHub (repositório `luqalefe/maestri-devops-lab`): variáveis
`AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN` e `TF_STATE_BUCKET`, e o environment
`production` com reviewer obrigatório e deployment branch policy só `main`. Os
ARNs dos roles saem do `output` do bootstrap.

**Dois roles, por menor privilégio** (ADR 3): com um só, qualquer PR assumiria o
role que faz apply.

| Role | Quem assume | Trust (claim `sub`) | Poder |
|---|---|---|---|
| `gha-plan` | `ci.yml` e o job `plan` do deploy | `repo:luqalefe/maestri-devops-lab:pull_request` e `…:ref:refs/heads/main` (ADR 7) | só leitura |
| `gha-deploy` | o job `apply` do deploy | `repo:luqalefe/maestri-devops-lab:environment:production` | aplica a infra |

**`ci.yml`** (todo pull request): pytest, `terraform fmt -check`, `init -backend=false`
+ `validate`, `tflint` e `checkov` — esses sem AWS — e depois `terraform plan -lock=false`
com o `gha-plan`, publicado como comentário no PR. O `-lock=false` (ADR 4) existe
porque o role de PR não escreve no bucket e o plan não altera o state. PR de fork
não recebe OIDC e o plan é pulado.

**`deploy.yml`** (só `workflow_dispatch`, em `main`):
1. job `plan`, sem environment: gera o plano, mostra no resumo do job e guarda como artifact;
2. o reviewer do environment `production` lê esse plano e aprova;
3. job `apply`, com o `gha-deploy`: baixa o artifact e aplica exatamente aquele plano
   (se o state mudou desde então, o Terraform recusa o plano velho).

Actions pinadas por SHA, `permissions` mínimas por job e nenhuma chave estática em
lugar nenhum.

## Destruir no fim

```sh
terraform -chdir=infra destroy
```

Remove a API, a Lambda, a tabela e os logs. **O bucket de state não some, de
propósito:** ele tem `prevent_destroy = true` (perder o state sem migração obriga
a reimportar tudo), então `terraform destroy` no bootstrap aborta no bucket.
Ele e o que o bootstrap criou sobram, com custo de centavos. Para conferir o que
restou:

```sh
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=maestri-devops-lab --region us-east-1
```

Só deve aparecer o que é do bootstrap. Se quiser apagar também o bucket, é uma
decisão consciente: tire o `prevent_destroy` no código, esvazie todas as versões
do bucket (ele é versionado) e só então destrua o bootstrap.
