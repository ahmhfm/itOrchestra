"""Audit-database access for the CrewAI service (Phase 0.10).

STRICT RULE COMPLIANCE: this module NEVER issues inline DML. It only *calls stored procedures
by name* and passes parameters (the database user is granted EXEC only, so direct table access
is impossible). Backend driver is pymssql; the database is CrewAiDb on the 0.7 AG primary.
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Any, Iterator, Optional

import pymssql

from config import CONFIG

log = logging.getLogger("crewai.db")


@contextmanager
def _conn() -> Iterator["pymssql.Connection"]:
    conn = pymssql.connect(
        server=CONFIG.db_host,
        port=CONFIG.db_port,
        user=CONFIG.db_user,
        password=CONFIG.db_password,
        database=CONFIG.db_name,
        login_timeout=CONFIG.db_login_timeout_s,
        timeout=CONFIG.db_login_timeout_s + 20,
        autocommit=True,  # each SP manages its own transaction internally
    )
    try:
        yield conn
    finally:
        conn.close()


def ping() -> bool:
    """Cheap connectivity probe (no business SP needed)."""
    try:
        with _conn() as c:
            cur = c.cursor()
            cur.execute("SELECT 1")
            cur.fetchall()
        return True
    except Exception as exc:  # noqa: BLE001 - boundary probe
        log.warning("audit db ping failed: %s", exc)
        return False


def insert_decision(
    *,
    decision_id: str,
    agent_kind: str,
    status: str,
    action: str,
    target: Optional[str],
    requires_approval: bool,
    rationale: Optional[str],
    requested_by: Optional[str],
    correlation_id: Optional[str],
    idempotency_key: Optional[str],
) -> dict[str, Any]:
    with _conn() as c:
        cur = c.cursor(as_dict=True)
        cur.callproc(
            "dbo.sp_CrewAi_Audit_InsertDecision",
            (
                decision_id,
                agent_kind,
                status,
                action,
                target,
                1 if requires_approval else 0,
                rationale,
                requested_by,
                correlation_id,
                idempotency_key,
            ),
        )
        rows = cur.fetchall()
        return rows[0] if rows else {"DecisionId": decision_id, "Status": status, "Replayed": False}


def add_source(
    *, decision_id: str, collection: str, point_id: Optional[str], score: Optional[float], snippet: Optional[str]
) -> None:
    with _conn() as c:
        cur = c.cursor()
        cur.callproc("dbo.sp_CrewAi_Audit_AddSource", (decision_id, collection, point_id, score, snippet))


def get_decision(decision_id: str) -> Optional[dict[str, Any]]:
    with _conn() as c:
        cur = c.cursor(as_dict=True)
        cur.callproc("dbo.sp_CrewAi_Audit_GetDecision", (decision_id,))
        rows = cur.fetchall()
        return rows[0] if rows else None


def get_sources(decision_id: str) -> list[dict[str, Any]]:
    with _conn() as c:
        cur = c.cursor(as_dict=True)
        cur.callproc("dbo.sp_CrewAi_Audit_GetSources", (decision_id,))
        return list(cur.fetchall())


def list_pending(agent_kind: Optional[str], limit: int) -> list[dict[str, Any]]:
    with _conn() as c:
        cur = c.cursor(as_dict=True)
        cur.callproc("dbo.sp_CrewAi_Approval_ListPending", (agent_kind, int(limit)))
        return list(cur.fetchall())


def set_approval(
    *, decision_id: str, approval_status: str, approver: str, reason: Optional[str]
) -> Optional[dict[str, Any]]:
    with _conn() as c:
        cur = c.cursor(as_dict=True)
        cur.callproc("dbo.sp_CrewAi_Approval_SetStatus", (decision_id, approval_status, approver, reason))
        rows = cur.fetchall()
        return rows[0] if rows else None
