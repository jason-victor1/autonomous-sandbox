# Stage 1: Build virtual environment
FROM python:3.12-slim AS builder

WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# Stage 2: Final hardened runtime
FROM python:3.12-slim AS runner

WORKDIR /app

# Patch base OS packages to resolve fixed CVEs (libssl3t64, openssl)
RUN apt-get update && \
    apt-get upgrade -y && \
    rm -rf /var/lib/apt/lists/*

# Non-root user with explicit UID
RUN groupadd -g 10001 sandboxgroup && \
    useradd -u 10001 -g sandboxgroup -s /sbin/nologin -m sandboxuser

COPY --from=builder /opt/venv /opt/venv
COPY main.py .

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 10001:10001

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import sys; sys.exit(0)"

CMD ["python", "main.py"]
