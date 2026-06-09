"""gRPC servicer for the CrewAI orchestration service (Phase 0.10).

Implements the CrewOrchestrator contract: route a task to an agent, ground it via Qdrant RAG,
reason on the local LLM, enforce the permissions matrix (auto -> advisory / approval -> pending
/ deny -> rejected), and persist every decision to the audit DB. Exceptions are caught at this
boundary and mapped to gRPC status codes (business errors vs. internal errors).
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

import grpc

import crew
import db
import tools
import crewai_pb2 as pb
import crewai_pb2_grpc as pb_grpc
from agents import AGENT_COLLECTION, PROFILES, route
from config import CONFIG
from permissions import evaluate, matrix_for

log = logging.getLogger("crewai.service")

# Statuses that mean "no system change happened" (read-only / advisory).
_READ_ACTIONS = {"read.kb", "query.rag", "analyze", "assess", "recommend", "report", "route", "plan"}


def _kind_name(value: int) -> str:
    name = pb.AgentKind.Name(value) if value else "AGENT_KIND_UNSPECIFIED"
    return name if name in PROFILES else "ORCHESTRATOR"


def _status_value(status: str) -> int:
    try:
        return pb.DecisionStatus.Value(status)
    except ValueError:
        return pb.DecisionStatus.DECISION_STATUS_UNSPECIFIED


def _correlation_id(context: grpc.ServicerContext) -> str:
    for key, val in context.invocation_metadata() or ():
        if key.lower() in ("x-correlation-id", "correlation-id"):
            return val
    return str(uuid.uuid4())


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class CrewOrchestratorServicer(pb_grpc.CrewOrchestratorServicer):
    # ---------- SubmitTask ----------
    def SubmitTask(self, request, context):
        corr = _correlation_id(context)
        try:
            agent = request.agent if request.agent else pb.AgentKind.Value(route(request.prompt, request.action))
            agent_name = _kind_name(agent)
            profile = PROFILES[agent_name]
            collection = request.collection or AGENT_COLLECTION.get(agent_name, CONFIG.default_collection)
            action = (request.action or "query.rag").strip().lower()
            ev = evaluate(agent_name, action)

            decision_id = str(uuid.uuid4())

            # Denied by policy: record and return without reasoning/executing.
            if ev.denied:
                status = "REJECTED"
                rationale = f"Action '{action}' is denied for agent {agent_name} by the permissions matrix."
                sources = []
            else:
                context_text, hits = tools.rag_context(request.prompt, collection, top_k=5)
                rationale = crew.reason(profile, request.prompt, context_text)
                sources = hits
                if ev.requires_approval:
                    status = "PENDING_APPROVAL"
                elif action in _READ_ACTIONS or ev.auto_allowed:
                    status = "ADVISORY"
                else:
                    status = "ADVISORY"

            result = db.insert_decision(
                decision_id=decision_id,
                agent_kind=agent_name,
                status=status,
                action=action,
                target=request.target or None,
                requires_approval=ev.requires_approval,
                rationale=rationale,
                requested_by=request.requested_by or None,
                correlation_id=corr,
                idempotency_key=request.idempotency_key or None,
            )

            effective_id = str(result.get("DecisionId") or decision_id)
            effective_status = str(result.get("Status") or status)
            replayed = bool(result.get("Replayed"))

            # On a fresh (non-replayed) decision, persist its RAG citations.
            if not replayed:
                for h in sources:
                    try:
                        db.add_source(
                            decision_id=effective_id,
                            collection=h.collection,
                            point_id=h.point_id,
                            score=h.score,
                            snippet=h.snippet,
                        )
                    except Exception as exc:  # noqa: BLE001
                        log.warning("add_source failed: %s", exc)

            return pb.TaskDecision(
                decision_id=effective_id,
                agent=pb.AgentKind.Value(agent_name),
                status=_status_value(effective_status),
                action=action,
                target=request.target,
                requires_approval=ev.requires_approval,
                rationale=rationale,
                sources=[self._src(h) for h in sources],
                requested_by=request.requested_by,
                created_at=_now(),
                correlation_id=corr,
            )
        except Exception as exc:  # noqa: BLE001 - boundary
            log.exception("SubmitTask failed [corr=%s]: %s", corr, exc)
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details("internal error handling task")
            return pb.TaskDecision(status=pb.DecisionStatus.FAILED, correlation_id=corr)

    # ---------- Query (RAG Q&A) ----------
    def Query(self, request, context):
        corr = _correlation_id(context)
        try:
            collection = request.collection or CONFIG.default_collection
            top_k = request.top_k or 5
            context_text, hits = tools.rag_context(request.question, collection, top_k)
            answer = crew.reason(PROFILES["ORCHESTRATOR"], request.question, context_text)

            # Every AI answer is auditable too (advisory, read-only).
            try:
                did = str(uuid.uuid4())
                db.insert_decision(
                    decision_id=did,
                    agent_kind="ORCHESTRATOR",
                    status="ADVISORY",
                    action="query.rag",
                    target=collection,
                    requires_approval=False,
                    rationale=answer,
                    requested_by=None,
                    correlation_id=corr,
                    idempotency_key=None,
                )
                for h in hits:
                    db.add_source(
                        decision_id=did, collection=h.collection, point_id=h.point_id, score=h.score, snippet=h.snippet
                    )
            except Exception as exc:  # noqa: BLE001 - auditing is best-effort for reads
                log.warning("Query audit failed: %s", exc)

            return pb.QueryResponse(
                answer=answer,
                sources=[self._src(h) for h in hits],
                correlation_id=corr,
            )
        except Exception as exc:  # noqa: BLE001
            log.exception("Query failed [corr=%s]: %s", corr, exc)
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details("internal error answering query")
            return pb.QueryResponse(correlation_id=corr)

    # ---------- Approvals ----------
    def ListPendingApprovals(self, request, context):
        try:
            agent = _kind_name(request.agent) if request.agent else None
            limit = request.limit or 50
            rows = db.list_pending(agent, limit)
            return pb.PendingApprovals(items=[self._row_to_decision(r) for r in rows])
        except Exception as exc:  # noqa: BLE001
            log.exception("ListPendingApprovals failed: %s", exc)
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details("internal error listing approvals")
            return pb.PendingApprovals()

    def ApproveAction(self, request, context):
        return self._decide(request, context, "APPROVED")

    def RejectAction(self, request, context):
        return self._decide(request, context, "REJECTED")

    def _decide(self, request, context, status: str):
        try:
            if not request.decision_id or not request.approver:
                context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
                context.set_details("decision_id and approver are required")
                return pb.TaskDecision()
            row = db.set_approval(
                decision_id=request.decision_id,
                approval_status=status,
                approver=request.approver,
                reason=request.reason or None,
            )
            if not row:
                context.set_code(grpc.StatusCode.NOT_FOUND)
                context.set_details("no pending approval for that decision_id")
                return pb.TaskDecision()
            return self._row_to_decision(row)
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            # Business errors raised by the SP (THROW 5001x) -> FailedPrecondition.
            if "No PENDING approval" in msg or "must be APPROVED" in msg:
                context.set_code(grpc.StatusCode.FAILED_PRECONDITION)
                context.set_details(msg)
                return pb.TaskDecision()
            log.exception("approval (%s) failed: %s", status, exc)
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details("internal error deciding approval")
            return pb.TaskDecision()

    # ---------- GetDecision ----------
    def GetDecision(self, request, context):
        try:
            row = db.get_decision(request.decision_id)
            if not row:
                context.set_code(grpc.StatusCode.NOT_FOUND)
                context.set_details("decision not found")
                return pb.TaskDecision()
            dec = self._row_to_decision(row)
            for s in db.get_sources(request.decision_id):
                dec.sources.append(
                    pb.SourceRef(
                        collection=s.get("Collection", ""),
                        point_id=str(s.get("PointId") or ""),
                        score=float(s.get("Score") or 0.0),
                        snippet=s.get("Snippet") or "",
                    )
                )
            return dec
        except Exception as exc:  # noqa: BLE001
            log.exception("GetDecision failed: %s", exc)
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details("internal error fetching decision")
            return pb.TaskDecision()

    # ---------- ListAgents ----------
    def ListAgents(self, request, context):
        agents = []
        for kind, p in PROFILES.items():
            perms = [
                pb.PermissionEntry(action=a, auto_allowed=auto, denied=deny) for (a, auto, deny) in matrix_for(kind)
            ]
            agents.append(
                pb.AgentProfile(
                    kind=pb.AgentKind.Value(kind),
                    name=p.name,
                    role=p.role,
                    goal=p.goal,
                    tools=list(p.tools),
                    permissions=perms,
                )
            )
        return pb.AgentCatalog(agents=agents)

    # ---------- Health ----------
    def Health(self, request, context):
        audit = db.ping()
        return pb.HealthResponse(
            ok=audit,
            llm_ok=tools.llm_ok(),
            vector_ok=tools.vector_ok(),
            audit_ok=audit,
            version=CONFIG.service_version,
        )

    # ---------- helpers ----------
    @staticmethod
    def _src(h) -> "pb.SourceRef":
        return pb.SourceRef(collection=h.collection, point_id=h.point_id, score=h.score, snippet=h.snippet)

    def _row_to_decision(self, row: dict) -> "pb.TaskDecision":
        created = row.get("CreatedAt")
        return pb.TaskDecision(
            decision_id=str(row.get("DecisionId") or ""),
            agent=pb.AgentKind.Value(row["AgentKind"]) if row.get("AgentKind") in PROFILES else 0,
            status=_status_value(str(row.get("Status") or "")),
            action=row.get("Action") or "",
            target=row.get("Target") or "",
            requires_approval=bool(row.get("RequiresApproval")),
            rationale=row.get("Rationale") or "",
            requested_by=row.get("RequestedBy") or "",
            created_at=created.isoformat() if hasattr(created, "isoformat") else str(created or ""),
            correlation_id=row.get("CorrelationId") or "",
        )
