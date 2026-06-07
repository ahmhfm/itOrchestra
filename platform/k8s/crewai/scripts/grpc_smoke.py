"""In-pod gRPC smoke test for the CrewAI service (Phase 0.10 verification).

Run *inside* the crewai pod (`kubectl exec -i deploy/crewai -- python - < grpc_smoke.py`) so it
can dial localhost:50051 directly (bypassing the Linkerd inbound, since loopback is not
redirected) and reuse the generated stubs already present in the image. Exercises the full
flow: Health, ListAgents, an approval-gated SubmitTask, the approval workflow, audit read-back,
and a RAG Query. Prints [PASS]/[FAIL] lines and a final 'TOTALS <pass> <fail>'.
"""
import sys

import grpc
import crewai_pb2 as pb
import crewai_pb2_grpc as g

DEADLINE = 300  # CPU LLM cold starts are slow; be generous.
PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def main():
    chan = grpc.insecure_channel("localhost:50051")
    grpc.channel_ready_future(chan).result(timeout=30)
    stub = g.CrewOrchestratorStub(chan)

    # Health
    try:
        h = stub.Health(pb.HealthRequest(), timeout=30)
        (ok if h.ok else bad)(f"Health ok={h.ok} llm={h.llm_ok} vector={h.vector_ok} audit={h.audit_ok}")
    except Exception as e:  # noqa: BLE001
        bad(f"Health RPC failed: {e}")

    # ListAgents (the 7 profiles)
    try:
        cat = stub.ListAgents(pb.ListAgentsRequest(), timeout=30)
        n = len(cat.agents)
        (ok if n >= 7 else bad)(f"ListAgents returned {n} agents (expected 7)")
    except Exception as e:  # noqa: BLE001
        bad(f"ListAgents RPC failed: {e}")

    # SubmitTask: an approval-gated action must be parked, not executed.
    decision_id = ""
    try:
        req = pb.SubmitTaskRequest(
            agent=pb.AgentKind.Value("PATCH"),
            prompt="Apply the latest security patch to host web01 during the maintenance window.",
            action="patch.apply",
            target="web01",
            requested_by="verifier",
        )
        d = stub.SubmitTask(req, timeout=DEADLINE)
        decision_id = d.decision_id
        want = pb.DecisionStatus.Value("PENDING_APPROVAL")
        if d.status == want and d.requires_approval:
            ok(f"SubmitTask(patch.apply) -> PENDING_APPROVAL (id={decision_id[:8]}..)")
        else:
            bad(f"SubmitTask status={pb.DecisionStatus.Name(d.status)} requires_approval={d.requires_approval}")
    except Exception as e:  # noqa: BLE001
        bad(f"SubmitTask RPC failed: {e}")

    # ListPendingApprovals contains it.
    if decision_id:
        try:
            pend = stub.ListPendingApprovals(pb.ListPendingApprovalsRequest(limit=50), timeout=30)
            ids = [x.decision_id for x in pend.items]
            (ok if decision_id in ids else bad)(
                f"ListPendingApprovals includes the decision ({len(ids)} pending)")
        except Exception as e:  # noqa: BLE001
            bad(f"ListPendingApprovals RPC failed: {e}")

        # Approve -> EXECUTED.
        try:
            d = stub.ApproveAction(
                pb.ApprovalDecisionRequest(decision_id=decision_id, approver="verifier", reason="ok"),
                timeout=30,
            )
            want = pb.DecisionStatus.Value("EXECUTED")
            (ok if d.status == want else bad)(
                f"ApproveAction -> {pb.DecisionStatus.Name(d.status)} (expected EXECUTED)")
        except Exception as e:  # noqa: BLE001
            bad(f"ApproveAction RPC failed: {e}")

        # Audit read-back: decision persisted with a rationale.
        try:
            d = stub.GetDecision(pb.GetDecisionRequest(decision_id=decision_id), timeout=30)
            persisted = d.decision_id == decision_id and bool(d.rationale)
            (ok if persisted else bad)(
                f"GetDecision audit persisted (status={pb.DecisionStatus.Name(d.status)}, "
                f"rationale_len={len(d.rationale)})")
        except Exception as e:  # noqa: BLE001
            bad(f"GetDecision RPC failed: {e}")

    # RAG Query (read-only; tolerant of an empty KB in a fresh cluster).
    try:
        q = stub.Query(pb.QueryRequest(question="What is our patch management policy?",
                                       collection="policies", top_k=5), timeout=DEADLINE)
        (ok if q.answer else bad)(f"Query returned an answer (len={len(q.answer)}, sources={len(q.sources)})")
    except Exception as e:  # noqa: BLE001
        bad(f"Query RPC failed: {e}")

    print(f"TOTALS {PASS} {FAIL}")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
