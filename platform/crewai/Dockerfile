# CrewAI orchestration service (Phase 0.10). Single-stage dev image on Python 3.12-slim.
# Runs as a non-root user so it satisfies the 'restricted' Pod Security Standard.
FROM python:3.14-slim

# Build deps for any sdists (pymssql ships manylinux wheels, but crewai's tree may compile).
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc g++ \
 && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=/home/appuser \
    XDG_CACHE_HOME=/tmp/.cache

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && pip install -r /app/requirements.txt

# App code + contract, then generate the gRPC stubs into /app (imported as top-level modules).
COPY app/ /app/
COPY proto/ /app/proto/
RUN python -m grpc_tools.protoc -I /app/proto \
        --python_out=/app --grpc_python_out=/app /app/proto/crewai.proto

# Non-root runtime user (restricted PSA: runAsNonRoot + a writable HOME/cache).
RUN useradd --uid 10001 --create-home --home-dir /home/appuser appuser \
 && mkdir -p /tmp/.cache && chown -R 10001:10001 /app /home/appuser /tmp/.cache
USER 10001

EXPOSE 50051
CMD ["python", "main.py"]
