"""Runtime configuration for the CrewAI orchestration service (Phase 0.10).

All values come from the environment (populated by the Kubernetes Deployment from Secrets /
ConfigMaps, which the install script seeds from Vault + the 0.9 AI layer). No secrets or
endpoints are hardcoded here.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _b(name: str, default: bool) -> bool:
    v = os.getenv(name)
    return default if v is None else v.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Config:
    # gRPC server
    grpc_port: int = int(os.getenv("GRPC_PORT", "50051"))
    service_version: str = os.getenv("SERVICE_VERSION", "0.10-dev")

    # LLM backend (Ollama in dev/CPU; vLLM in prod/GPU - same OpenAI-compatible surface).
    llm_base_url: str = os.getenv("LLM_BASE_URL", "http://ollama.ai.svc.cluster.local:11434/v1")
    chat_model: str = os.getenv("CHAT_MODEL", "qwen2.5:1.5b")
    # Ollama-native embedding endpoint (separate from the OpenAI-compatible chat surface).
    ollama_base_url: str = os.getenv("OLLAMA_BASE_URL", "http://ollama.ai.svc.cluster.local:11434")
    embed_model: str = os.getenv("EMBED_MODEL", "bge-m3")
    llm_timeout_s: int = int(os.getenv("LLM_TIMEOUT_S", "120"))
    max_tokens: int = int(os.getenv("MAX_TOKENS", "128"))
    # Dev/CPU default: a single direct LLM call (fast). CrewAI's multi-step crew loop is far
    # slower on CPU; enable it (USE_CREWAI=true) on the prod/GPU profile where it is practical.
    use_crewai: bool = _b("USE_CREWAI", False)

    # Vector store (Qdrant).
    qdrant_url: str = os.getenv("QDRANT_URL", "http://qdrant.ai.svc.cluster.local:6333")
    qdrant_api_key: str = os.getenv("QDRANT_API_KEY", "")
    default_collection: str = os.getenv("DEFAULT_COLLECTION", "knowledge_base")
    qdrant_timeout_s: int = int(os.getenv("QDRANT_TIMEOUT_S", "15"))

    # Audit database (CrewAiDb on the 0.7 AG primary). App calls stored procedures ONLY.
    db_host: str = os.getenv("DB_HOST", "mssql-ag-primary.mssql.svc.cluster.local")
    db_port: int = int(os.getenv("DB_PORT", "1433"))
    db_name: str = os.getenv("DB_NAME", "CrewAiDb")
    db_user: str = os.getenv("DB_USER", "crewai_app")
    db_password: str = os.getenv("DB_PASSWORD", "")
    db_login_timeout_s: int = int(os.getenv("DB_LOGIN_TIMEOUT_S", "10"))


CONFIG = Config()
