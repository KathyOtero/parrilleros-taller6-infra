FROM python:3.12-alpine3.22 AS builder

WORKDIR /build

COPY requirements.txt .

RUN python -m pip install \
    --no-cache-dir \
    --only-binary=:all: \
    --prefix=/install \
    -r requirements.txt


FROM python:3.12-alpine3.22

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apk upgrade --no-cache \
    && addgroup -S -g 10001 appgroup \
    && adduser -S -D -H -u 10001 -G appgroup appuser

WORKDIR /app

COPY --from=builder /install /usr/local
COPY --chown=10001:10001 main.py .

USER 10001:10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-server-header"]