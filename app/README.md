# Items API — Taller 6 · LOS PARRILLEROS (Integrante 2)

API REST en Python/FastAPI que guarda elementos en **Amazon DynamoDB** usando el **rol IAM** del servicio (sin claves en código ni en la imagen).

## Endpoints

| Método | Ruta | Respuesta |
|--------|------|-----------|
| GET | `/health` | `200 {"status":"ok","version":"<APP_VERSION>"}` — no consulta la BD |
| POST | `/items` | Body `{"name": "...", "description": "..."}` → `201` con `id` (UUID) y `created_at` |
| GET | `/items?limit=50` | `200` lista (máx. 100) ordenada por fecha desc. |

Errores: `422` validación · `503` si DynamoDB falla (queda en el log).

## Contrato con el resto del equipo

| Para | Dato |
|------|------|
| Integrante 1 (BD/IAM) | Tabla con partition key `id` (String), `PAY_PER_REQUEST`. El rol de la app solo necesita **`dynamodb:PutItem`** y **`dynamodb:Scan`** sobre el ARN de la tabla. |
| Integrante 3 (cómputo) | Puerto **8080**, health check **`GET /health`**. Variables: `TABLE_NAME`, `AWS_REGION`, `APP_VERSION` (opcional `LOG_LEVEL`). **No** definir `DYNAMODB_ENDPOINT` ni claves AWS en la nube. |
| Integrante 4 (CI/CD) | `docker build ./app`; Trivy con `--severity CRITICAL --exit-code 1 --ignore-unfixed`. Pasar `APP_VERSION` = SHA del commit. Logs salen por stdout → CloudWatch. |

## Cómo se autentica sin credenciales

`boto3` usa la cadena de credenciales por defecto de AWS: en App Runner/ECS toma el rol IAM asignado al servicio; en local toma el perfil de `aws configure`/`aws sso login`. Por eso el código nunca lee una access key.

## Correr en local (sin AWS)

```bash
cd app
docker compose up -d --build          # API + DynamoDB Local + crea la tabla
./test_api.sh                         # prueba de humo (health, POST, GET, 422)
docker compose logs -f api            # ver logs
docker compose down
```

Si el puerto 8080 está ocupado: `API_PORT=8088 docker compose up -d` y `./test_api.sh http://localhost:8088`.
Las credenciales `local/local` del compose son falsas y solo sirven para DynamoDB Local.

Contra la nube: `./test_api.sh https://<url-app-runner>` o usar `requests.http` (extensión REST Client de VS Code).

## Seguridad de la imagen

- Multi-stage: pip y la caché de build no llegan a la imagen final.
- Base `python:3.12-slim` + `apt-get upgrade` para parches del SO.
- Usuario no-root `appuser` (UID 10001), `HEALTHCHECK` incluido, sin header `Server`.
- Escaneo:
  ```bash
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.67.2 \
    image --severity HIGH,CRITICAL --ignore-unfixed app-api
  ```
  Resultado al 2026-10-14: **0 HIGH / 0 CRITICAL**.
