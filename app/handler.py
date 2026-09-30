import base64
import json
from decimal import Decimal
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

TITULO_MAX = 200
# Limite de tamanho da chave de partição do DynamoDB; acima disso a AWS
# rejeita com ValidationException (o moto não), então o código valida antes.
ID_MAX_BYTES = 2048
LIMITE_PADRAO = 50
# 100 itens de ~1 KB ficam muito abaixo dos 6 MB de resposta da Lambda.
LIMITE_MAX = 100

# A tabela é criada por chamada, não no import: o moto só intercepta o boto3
# depois que o teste sobe o mock, e no Lambda o custo é desprezível (o
# recurso é barato e o container é reaproveitado).
def _tabela():
    return boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def _serializar(obj):
    # O boto3 devolve Number como Decimal e conjuntos como set; o json.dumps
    # não conhece nenhum dos dois, e um só item assim derrubaria a listagem
    # inteira. Inteiro continua inteiro, para não virar 3.0 na resposta.
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    if isinstance(obj, (set, frozenset)):
        return sorted(obj)
    raise TypeError(f"{type(obj).__name__} não é serializável")


def _resposta(status, corpo=None):
    # 204 não tem corpo; mandar "null" quebraria clientes que respeitam a RFC.
    if corpo is None:
        return {"statusCode": status}
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(corpo, ensure_ascii=False, default=_serializar),
    }


def _erro(status, mensagem):
    return _resposta(status, {"error": mensagem})


def _ler_corpo(event):
    """Devolve (dict, None) ou (None, mensagem de erro)."""
    bruto = event.get("body")
    if not bruto:
        return None, "corpo obrigatório"
    # O API Gateway pode entregar o corpo em base64 conforme o content-type.
    if event.get("isBase64Encoded"):
        try:
            bruto = base64.b64decode(bruto).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None, "corpo inválido"
    try:
        dados = json.loads(bruto)
    except json.JSONDecodeError:
        return None, "corpo não é JSON válido"
    if not isinstance(dados, dict):
        return None, "corpo deve ser um objeto JSON"
    return dados, None


def _validar_titulo(dados):
    titulo = dados.get("title")
    if not isinstance(titulo, str) or not titulo.strip():
        return None, "title é obrigatório e deve ser texto não vazio"
    titulo = titulo.strip()
    # Surrogate solto (ex.: "\ud800") passa pelo json.loads mas não tem
    # codificação UTF-8; sem essa checagem estoura só no put_item, como 500.
    try:
        titulo.encode("utf-8")
    except UnicodeEncodeError:
        return None, "title contém caracteres inválidos"
    if len(titulo) > TITULO_MAX:
        return None, f"title deve ter no máximo {TITULO_MAX} caracteres"
    return titulo, None


def _id_valido(id_):
    if not isinstance(id_, str) or not id_:
        return False
    try:
        return len(id_.encode("utf-8")) <= ID_MAX_BYTES
    except UnicodeEncodeError:
        return False


def _id_da_rota(event):
    return (event.get("pathParameters") or {}).get("id")


def _codificar_cursor(chave):
    bruto = json.dumps(chave, ensure_ascii=False).encode("utf-8")
    return base64.urlsafe_b64encode(bruto).decode("ascii")


def _decodificar_cursor(cursor):
    """Devolve a ExclusiveStartKey ou None se o cursor for inválido."""
    try:
        chave = json.loads(base64.urlsafe_b64decode(cursor.encode("ascii")))
    except (ValueError, UnicodeError):
        return None
    # O cursor vem do cliente: só aceitamos a forma exata da nossa chave,
    # para ele não injetar atributos arbitrários no scan.
    if not isinstance(chave, dict) or set(chave) != {"id"}:
        return None
    return chave if _id_valido(chave["id"]) else None


def listar_tarefas(event):
    """GET /tasks?limit=<1..100, padrão 50>&cursor=<opaco>

    Uma página por chamada. Resposta 200:
        {"tasks": [{"id", "title", "created_at", ...}], "next_cursor": str | null}
    Se next_cursor não for null, repita a chamada com cursor=<next_cursor>
    para a próxima página; null significa fim da listagem. A ordem não é
    garantida (é um scan). Limite fora da faixa ou cursor inválido: 400.
    """
    params = event.get("queryStringParameters") or {}
    limite = LIMITE_PADRAO
    if "limit" in params:
        try:
            limite = int(params["limit"])
        except ValueError:
            return _erro(400, "limit deve ser um inteiro")
        if not 1 <= limite <= LIMITE_MAX:
            return _erro(400, f"limit deve estar entre 1 e {LIMITE_MAX}")

    args = {"Limit": limite}
    if params.get("cursor"):
        inicio = _decodificar_cursor(params["cursor"])
        if inicio is None:
            return _erro(400, "cursor inválido")
        args["ExclusiveStartKey"] = inicio

    resp = _tabela().scan(**args)
    ultima = resp.get("LastEvaluatedKey")
    return _resposta(
        200,
        {
            "tasks": resp["Items"],
            "next_cursor": _codificar_cursor(ultima) if ultima else None,
        },
    )


def criar_tarefa(event):
    dados, erro = _ler_corpo(event)
    if erro:
        return _erro(400, erro)
    titulo, erro = _validar_titulo(dados)
    if erro:
        return _erro(400, erro)
    # Só title vem do cliente; id e created_at são nossos, para o cliente não
    # forjar chave nem sobrescrever tarefa alheia.
    tarefa = {
        "id": str(uuid.uuid4()),
        "title": titulo,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _tabela().put_item(Item=tarefa)
    return _resposta(201, tarefa)


def buscar_tarefa(event):
    id_ = _id_da_rota(event)
    if not _id_valido(id_):
        return _erro(404, "tarefa não encontrada")
    item = _tabela().get_item(Key={"id": id_}).get("Item")
    if item is None:
        return _erro(404, "tarefa não encontrada")
    return _resposta(200, item)


def apagar_tarefa(event):
    id_ = _id_da_rota(event)
    if not _id_valido(id_):
        return _erro(404, "tarefa não encontrada")
    try:
        # A condição faz existência e delete numa operação só; um get antes
        # deixaria janela para o item sumir entre as duas chamadas.
        _tabela().delete_item(
            Key={"id": id_}, ConditionExpression="attribute_exists(id)"
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _erro(404, "tarefa não encontrada")
        raise
    return _resposta(204)


ROTAS = {
    "GET /tasks": listar_tarefas,
    "POST /tasks": criar_tarefa,
    "GET /tasks/{id}": buscar_tarefa,
    "DELETE /tasks/{id}": apagar_tarefa,
}


def handler(event, context):
    # routeKey é a rota casada pelo próprio API Gateway; usar ele evita
    # reimplementar parsing de path e método.
    rota = ROTAS.get(event.get("routeKey"))
    if rota is None:
        return _erro(404, "rota não encontrada")
    return rota(event)
