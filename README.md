# maestri-devops-lab

API de tarefas descartável, usada como laboratório do andar **DevOps** do Maestri.
Nasce e morre no mesmo dia: o que vale aqui é medir como os agentes colaboram até
um deploy validado e um `destroy` limpo.

O briefing, as regras, as tarefas, os ADR e o diário estão em
`~/code/partituras/notas/devops-agora.md`, que é a fonte de verdade.

## Stack

Lambda (Python 3.12) + API Gateway HTTP API + DynamoDB on-demand, tudo em
Terraform com state remoto em S3, e GitHub Actions com OIDC para a AWS.

## Rodar os testes

```sh
python3 -m venv .venv && .venv/bin/pip install -r app/requirements.txt -r app/requirements-dev.txt
.venv/bin/python -m pytest app/tests -q
```

A suíte usa `moto`, então não fala com a AWS e não precisa de credencial.
