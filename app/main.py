"""API de elementos - Taller 6 (LOS PARRILLEROS).

Credenciales: boto3 usa la cadena de credenciales por defecto de AWS.
  - En la nube: rol IAM de la instancia (App Runner / ECS), sin claves.
  - En local: perfil de `aws configure` / `aws sso login`, o DynamoDB Local.
Nunca se escriben access keys en el código ni en la imagen.

Permisos IAM que necesita la app (mínimo privilegio, sobre la tabla):
  - dynamodb:PutItem  -> POST /items
  - dynamodb:Scan     -> GET /items
"""

import logging
import os
import sys
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Query, Request
from pydantic import BaseModel, Field

TABLE_NAME = os.getenv("TABLE_NAME", "items")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
APP_VERSION = os.getenv("APP_VERSION", "dev")
# Solo para pruebas locales con DynamoDB Local; en la nube queda vacío.
DYNAMODB_ENDPOINT = os.getenv("DYNAMODB_ENDPOINT") or None

logging.basicConfig(
    stream=sys.stdout,
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("items-api")

table = boto3.resource(
    "dynamodb", region_name=AWS_REGION, endpoint_url=DYNAMODB_ENDPOINT
).Table(TABLE_NAME)

app = FastAPI(title="Items API - Los Parrilleros", version=APP_VERSION)


class ItemIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=500)


class Item(ItemIn):
    id: str
    created_at: str


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        log.exception("unhandled error method=%s path=%s", request.method, request.url.path)
        raise
    elapsed_ms = (time.perf_counter() - start) * 1000
    log.info(
        "request method=%s path=%s status=%s duration_ms=%.1f",
        request.method, request.url.path, response.status_code, elapsed_ms,
    )
    return response


@app.get("/health")
def health():
    # Liveness: no consulta la BD para que un fallo transitorio de DynamoDB
    # no haga que el servicio reinicie el contenedor.
    return {"status": "ok", "version": APP_VERSION}


@app.post("/items", response_model=Item, status_code=201)
def create_item(payload: ItemIn):
    item = Item(
        id=str(uuid.uuid4()),
        created_at=datetime.now(timezone.utc).isoformat(),
        **payload.model_dump(),
    )
    try:
        table.put_item(
            Item=item.model_dump(exclude_none=True),
            ConditionExpression="attribute_not_exists(id)",
        )
    except (ClientError, BotoCoreError) as e:
        log.error("dynamodb put_item failed: %s", e)
        raise HTTPException(status_code=503, detail="database unavailable")
    log.info("item created id=%s", item.id)
    return item


@app.get("/items", response_model=list[Item])
def list_items(limit: int = Query(default=50, ge=1, le=100)):
    try:
        result = table.scan(Limit=limit)
    except (ClientError, BotoCoreError) as e:
        log.error("dynamodb scan failed: %s", e)
        raise HTTPException(status_code=503, detail="database unavailable")
    items = result.get("Items", [])
    return sorted(items, key=lambda i: i.get("created_at", ""), reverse=True)
