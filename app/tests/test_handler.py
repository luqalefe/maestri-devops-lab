import base64
import json
import os
from decimal import Decimal
import sys

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import handler as h  # noqa: E402

TABELA = "tasks-teste"


@pytest.fixture(autouse=True)
def ambiente(monkeypatch):
    # Valores falsos de propósito: o moto exige alguma credencial no ambiente,
    # e assim nenhum teste consegue falar com a AWS de verdade.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("TABLE_NAME", TABELA)


@pytest.fixture
def tabela(ambiente):
    with mock_aws():
        ddb = boto3.resource("dynamodb")
        yield ddb.create_table(
            TableName=TABELA,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )


def evento(rota, corpo=None, id_=None, base64_=False):
    ev = {"version": "2.0", "routeKey": rota}
    if id_ is not None:
        ev["pathParameters"] = {"id": id_}
    if corpo is not None:
        ev["body"] = corpo
    if base64_:
        ev["isBase64Encoded"] = True
    return ev


def chamar(*args, **kwargs):
    return h.handler(evento(*args, **kwargs), None)


def criar(titulo="comprar pão"):
    r = chamar("POST /tasks", json.dumps({"title": titulo}))
    assert r["statusCode"] == 201
    return json.loads(r["body"])


# --- POST /tasks

def test_post_cria_tarefa_com_201(tabela):
    r = chamar("POST /tasks", json.dumps({"title": "  estudar  "}))
    corpo = json.loads(r["body"])
    assert r["statusCode"] == 201
    assert r["headers"]["content-type"] == "application/json"
    assert corpo["title"] == "estudar"
    assert corpo["id"] and corpo["created_at"]
    assert tabela.get_item(Key={"id": corpo["id"]})["Item"]["title"] == "estudar"


def test_post_ignora_id_enviado_pelo_cliente(tabela):
    r = chamar("POST /tasks", json.dumps({"title": "x", "id": "forjado"}))
    assert json.loads(r["body"])["id"] != "forjado"


def test_post_aceita_corpo_em_base64(tabela):
    bruto = base64.b64encode(json.dumps({"title": "b64"}).encode()).decode()
    r = chamar("POST /tasks", bruto, base64_=True)
    assert r["statusCode"] == 201


@pytest.mark.parametrize(
    "corpo",
    [
        None,
        "",
        "não é json",
        "[1, 2]",
        "null",
        "{}",
        json.dumps({"title": ""}),
        json.dumps({"title": "   "}),
        json.dumps({"title": 42}),
        '{"title": "\\ud800"}',
        '{"title": "ok\\udfff"}',
        json.dumps({"title": "a" * (h.TITULO_MAX + 1)}),
    ],
)
def test_post_corpo_invalido_retorna_400(tabela, corpo):
    r = chamar("POST /tasks", corpo)
    assert r["statusCode"] == 400
    assert "error" in json.loads(r["body"])
    assert tabela.scan()["Count"] == 0


def test_post_base64_invalido_retorna_400(tabela):
    r = chamar("POST /tasks", "\xff\xfe", base64_=True)
    assert r["statusCode"] == 400


# --- GET /tasks

def test_get_lista_vazia_retorna_200(tabela):
    r = chamar("GET /tasks")
    assert r["statusCode"] == 200
    assert json.loads(r["body"]) == {"tasks": [], "next_cursor": None}


def test_get_lista_devolve_tarefas_criadas(tabela):
    a, b = criar("a"), criar("b")
    r = chamar("GET /tasks")
    ids = {t["id"] for t in json.loads(r["body"])["tasks"]}
    assert r["statusCode"] == 200
    assert ids == {a["id"], b["id"]}


def listar(**params):
    r = h.handler({"routeKey": "GET /tasks", "queryStringParameters": params or None}, None)
    return r, (json.loads(r["body"]) if "body" in r else None)


def test_get_lista_pagina_e_cursor_percorrem_tudo(tabela):
    criados = {criar(f"t{i}")["id"] for i in range(5)}
    vistos, cursor, paginas = [], None, 0
    while True:
        params = {"limit": "2"} | ({"cursor": cursor} if cursor else {})
        r, corpo = listar(**params)
        assert r["statusCode"] == 200
        assert len(corpo["tasks"]) <= 2
        vistos += [t["id"] for t in corpo["tasks"]]
        paginas += 1
        cursor = corpo["next_cursor"]
        if cursor is None:
            break
    assert paginas >= 3
    assert len(vistos) == 5 and set(vistos) == criados


def test_get_lista_respeita_limite_padrao(tabela, monkeypatch):
    monkeypatch.setattr(h, "LIMITE_PADRAO", 2)
    for i in range(3):
        criar(f"t{i}")
    _, corpo = listar()
    assert len(corpo["tasks"]) == 2
    assert corpo["next_cursor"]


@pytest.mark.parametrize("limit", ["0", "-1", "101", "abc", "1.5", ""])
def test_get_lista_limit_invalido_retorna_400(tabela, limit):
    r, _ = listar(limit=limit)
    assert r["statusCode"] == 400


@pytest.mark.parametrize(
    "cursor",
    [
        "lixo!!",
        base64.urlsafe_b64encode(b"nao json").decode(),
        base64.urlsafe_b64encode(b'["id"]').decode(),
        base64.urlsafe_b64encode(b'{"outro": "x"}').decode(),
        base64.urlsafe_b64encode(b'{"id": "x", "extra": 1}').decode(),
        base64.urlsafe_b64encode(b'{"id": 5}').decode(),
        base64.urlsafe_b64encode(b'{"id": ""}').decode(),
        "\u00e9",
    ],
)
def test_get_lista_cursor_invalido_retorna_400(tabela, cursor):
    r, _ = listar(cursor=cursor)
    assert r["statusCode"] == 400


def test_get_lista_serializa_number_e_set(tabela):
    # Item gravado "por fora" (console, TTL, campo futuro): não pode derrubar a listagem.
    tabela.put_item(
        Item={
            "id": "x",
            "title": "t",
            "prioridade": Decimal("3"),
            "nota": Decimal("2.5"),
            "tags": {"b", "a"},
            "pesos": {Decimal("2"), Decimal("1")},
        }
    )
    r, corpo = listar()
    item = corpo["tasks"][0]
    assert r["statusCode"] == 200
    assert item["prioridade"] == 3 and isinstance(item["prioridade"], int)
    assert item["nota"] == 2.5
    assert item["tags"] == ["a", "b"]
    assert item["pesos"] == [1, 2]


def test_get_por_id_serializa_number(tabela):
    tabela.put_item(Item={"id": "x", "title": "t", "prioridade": Decimal("3")})
    r = chamar("GET /tasks/{id}", id_="x")
    assert r["statusCode"] == 200
    assert json.loads(r["body"])["prioridade"] == 3


# --- GET /tasks/{id}

def test_get_por_id_retorna_200(tabela):
    t = criar()
    r = chamar("GET /tasks/{id}", id_=t["id"])
    assert r["statusCode"] == 200
    assert json.loads(r["body"]) == t


def test_get_por_id_inexistente_retorna_404(tabela):
    r = chamar("GET /tasks/{id}", id_="nao-existe")
    assert r["statusCode"] == 404
    assert "error" in json.loads(r["body"])


# --- DELETE /tasks/{id}

def test_delete_retorna_204_sem_corpo_e_apaga(tabela):
    t = criar()
    r = chamar("DELETE /tasks/{id}", id_=t["id"])
    assert r["statusCode"] == 204
    assert "body" not in r
    assert chamar("GET /tasks/{id}", id_=t["id"])["statusCode"] == 404


def test_delete_id_inexistente_retorna_404(tabela):
    r = chamar("DELETE /tasks/{id}", id_="nao-existe")
    assert r["statusCode"] == 404


def test_delete_duas_vezes_segunda_retorna_404(tabela):
    t = criar()
    assert chamar("DELETE /tasks/{id}", id_=t["id"])["statusCode"] == 204
    assert chamar("DELETE /tasks/{id}", id_=t["id"])["statusCode"] == 404


# --- rotas desconhecidas

@pytest.mark.parametrize("rota", ["PUT /tasks/{id}", "GET /outra", "$default", None])
def test_rota_desconhecida_retorna_404(tabela, rota):
    assert chamar(rota)["statusCode"] == 404


# --- id inválido para o DynamoDB: 404, nunca 500

IDS_INVALIDOS = ["", "a" * 2049, "é" * 1025, "\ud800"]


@pytest.mark.parametrize("id_", IDS_INVALIDOS)
@pytest.mark.parametrize("rota", ["GET /tasks/{id}", "DELETE /tasks/{id}"])
def test_id_invalido_retorna_404(tabela, rota, id_):
    assert chamar(rota, id_=id_)["statusCode"] == 404


@pytest.mark.parametrize("rota", ["GET /tasks/{id}", "DELETE /tasks/{id}"])
def test_sem_path_parameters_retorna_404(tabela, rota):
    assert h.handler({"routeKey": rota}, None)["statusCode"] == 404
    assert h.handler({"routeKey": rota, "pathParameters": None}, None)["statusCode"] == 404


def test_id_no_limite_de_2048_bytes_vai_ao_banco_e_da_404(tabela):
    assert chamar("GET /tasks/{id}", id_="a" * 2048)["statusCode"] == 404


@pytest.mark.parametrize("rota", ["GET /tasks/{id}", "DELETE /tasks/{id}"])
def test_id_acima_de_2048_bytes_nem_chega_ao_dynamodb(tabela, monkeypatch, rota):
    # O moto aceita chave gigante; a AWS real não. Por isso o teste garante que
    # a validação acontece antes da chamada, em vez de depender do mock.
    def nao_deveria_chamar():
        raise AssertionError("id inválido chegou ao DynamoDB")

    monkeypatch.setattr(h, "_tabela", nao_deveria_chamar)
    assert chamar(rota, id_="a" * 2049)["statusCode"] == 404
