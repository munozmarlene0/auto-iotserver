# =============================================================================
# Dockerfile - FastAPI para Plataforma IoT
# =============================================================================
FROM python:3.11-slim

LABEL maintainer="iot-platform"
LABEL version="1.1"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# Crear usuario no-root
RUN groupadd -r fastapi && useradd -r -g fastapi fastapi

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    default-libmysqlclient-dev \
    pkg-config \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copiar e instalar dependencias
COPY --chown=fastapi:fastapi requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar código de la aplicación
COPY --chown=fastapi:fastapi . .

# Crear directorios de logs
RUN mkdir -p /var/log/fastapi/sessions && chown -R fastapi:fastapi /var/log/fastapi

USER fastapi

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5000", "--workers", "2", "--proxy-headers"]
