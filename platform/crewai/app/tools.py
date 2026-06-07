"""Agent tools (Phase 0.10).

Real (read-only) tools: embeddings + chat on the local LLM (Ollama) and RAG search over Qdrant.
Action tools are SAFE STUBS in dev - they describe what *would* be done but never touch a real
system, because the target services (assets/discovery/etc.) do not exist yet. When those land,
the stubs are replaced by gRPC calls to the owning services (never direct DB access).
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

import requests

from config import CONFIG

log = logging.getLogger("crewai.tools")


@dataclass(frozen=True)
class SourceHit:
    collection: str
    point_id: str
    score: float
    snippet: str


# ---------- LLM (Ollama / vLLM, OpenAI-compatible chat) ----------

def llm_chat(system_prompt: str, user_prompt: str, *, max_tokens: int | None = None, temperature: float = 0.2) -> str:
    url = f"{CONFIG.llm_base_url.rstrip('/')}/chat/completions"
    payload = {
        "model": CONFIG.chat_model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": max_tokens or CONFIG.max_tokens,
        "temperature": temperature,
    }
    resp = requests.post(url, json=payload, timeout=CONFIG.llm_timeout_s)
    resp.raise_for_status()
    data = resp.json()
    return data["choices"][0]["message"]["content"].strip()


def llm_ok() -> bool:
    try:
        r = requests.get(f"{CONFIG.ollama_base_url.rstrip('/')}/api/tags", timeout=5)
        return r.status_code == 200
    except Exception as exc:  # noqa: BLE001
        log.warning("llm health failed: %s", exc)
        return False


# ---------- Embeddings (Ollama native) ----------

def embed(text: str) -> list[float]:
    url = f"{CONFIG.ollama_base_url.rstrip('/')}/api/embed"
    resp = requests.post(url, json={"model": CONFIG.embed_model, "input": text}, timeout=CONFIG.llm_timeout_s)
    resp.raise_for_status()
    data = resp.json()
    if "embeddings" in data and data["embeddings"]:
        return data["embeddings"][0]
    if "embedding" in data:
        return data["embedding"]
    raise ValueError("unexpected embedding response shape")


# ---------- Vector search (Qdrant) ----------

def _qdrant_headers() -> dict[str, str]:
    h = {"Content-Type": "application/json"}
    if CONFIG.qdrant_api_key:
        h["api-key"] = CONFIG.qdrant_api_key
    return h


def vector_ok() -> bool:
    try:
        r = requests.get(f"{CONFIG.qdrant_url.rstrip('/')}/readyz", headers=_qdrant_headers(), timeout=5)
        return r.status_code == 200
    except Exception as exc:  # noqa: BLE001
        log.warning("qdrant health failed: %s", exc)
        return False


def _extract_snippet(payload: Optional[dict]) -> str:
    if not payload:
        return ""
    for key in ("text", "content", "snippet", "title", "summary"):
        if key in payload and payload[key]:
            return str(payload[key])[:500]
    return str(payload)[:500]


def qdrant_search(collection: str, vector: list[float], top_k: int = 5) -> list[SourceHit]:
    url = f"{CONFIG.qdrant_url.rstrip('/')}/collections/{collection}/points/search"
    body = {"vector": vector, "limit": int(top_k), "with_payload": True}
    resp = requests.post(url, json=body, headers=_qdrant_headers(), timeout=CONFIG.qdrant_timeout_s)
    resp.raise_for_status()
    result = resp.json().get("result", []) or []
    hits: list[SourceHit] = []
    for item in result:
        hits.append(
            SourceHit(
                collection=collection,
                point_id=str(item.get("id", "")),
                score=float(item.get("score", 0.0)),
                snippet=_extract_snippet(item.get("payload")),
            )
        )
    return hits


def rag_context(question: str, collection: str, top_k: int = 5) -> tuple[str, list[SourceHit]]:
    """Embed the question, search Qdrant, and assemble a grounding context block.

    Tolerant by design: if embeddings/search fail or the collection is empty (expected in a
    fresh dev cluster), returns an empty context so reasoning can still proceed (ungrounded).
    """
    try:
        vec = embed(question)
        hits = qdrant_search(collection, vec, top_k)
    except Exception as exc:  # noqa: BLE001 - RAG is best-effort grounding
        log.warning("rag_context failed for %s: %s", collection, exc)
        return "", []

    if not hits:
        return "", []
    context = "\n\n".join(f"[{i+1}] {h.snippet}" for i, h in enumerate(hits) if h.snippet)
    return context, hits


# ---------- Safe action stubs (dev) ----------

def stub_action(agent_kind: str, action: str, target: Optional[str], rationale: str) -> str:
    tgt = target or "(unspecified target)"
    return (
        f"[DEV-STUB] Agent '{agent_kind}' prepared action '{action}' against {tgt}. "
        f"No real change was performed. Once the owning service exists, this becomes a gRPC call. "
        f"Plan: {rationale[:400]}"
    )
