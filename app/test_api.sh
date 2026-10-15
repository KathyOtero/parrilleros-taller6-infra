#!/usr/bin/env bash
# Prueba de humo de la API. Uso: ./test_api.sh [BASE_URL]
# Ej. nube: ./test_api.sh https://xxxx.us-east-1.awsapprunner.com
set -euo pipefail
BASE_URL="${1:-http://localhost:8080}"
fail() { echo "FALLO: $1"; exit 1; }

echo "== GET /health"
code=$(curl -s -o /tmp/health.json -w '%{http_code}' "$BASE_URL/health")
cat /tmp/health.json; echo
[ "$code" = 200 ] || fail "health devolvió $code"

echo "== POST /items"
code=$(curl -s -o /tmp/post.json -w '%{http_code}' -X POST "$BASE_URL/items" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Prueba smoke","description":"creado por test_api.sh"}')
cat /tmp/post.json; echo
[ "$code" = 201 ] || fail "POST devolvió $code"
id=$(python3 -c 'import json;print(json.load(open("/tmp/post.json"))["id"])')

echo "== GET /items"
code=$(curl -s -o /tmp/list.json -w '%{http_code}' "$BASE_URL/items")
cat /tmp/list.json; echo
[ "$code" = 200 ] || fail "GET devolvió $code"
grep -q "$id" /tmp/list.json || fail "el elemento $id no aparece en la lista"

echo "== POST inválido (espera 422)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/items" \
  -H 'Content-Type: application/json' -d '{"name":""}')
[ "$code" = 422 ] || fail "validación devolvió $code"

echo "OK: todas las pruebas pasaron"
