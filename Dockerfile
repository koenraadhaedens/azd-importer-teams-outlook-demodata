FROM python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704 AS builder
WORKDIR /build
COPY pyproject.toml requirements.lock ./
COPY src ./src
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --require-hashes -r requirements.lock \
    && /opt/venv/bin/pip install --no-cache-dir --no-deps .

FROM python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704 AS runtime
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DATA_DIR=/app/data
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --create-home app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app templates ./templates
COPY --chown=app:app static ./static
COPY --chown=app:app config ./config
COPY --chown=app:app schemas ./schemas
RUN mkdir data && chown app:app data
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s \
  CMD python -c "import os,urllib.request; r=urllib.request.Request('http://127.0.0.1:8000/healthz',headers={'Host':__import__('urllib.parse',fromlist=['urlparse']).urlparse(os.environ['PUBLIC_URL']).netloc}); urllib.request.urlopen(r,timeout=4)"
CMD ["uvicorn", "demo_loader.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-proxy-headers", "--no-access-log"]
