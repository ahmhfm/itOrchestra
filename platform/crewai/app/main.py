"""Entrypoint for the CrewAI orchestration gRPC server (Phase 0.10)."""
from __future__ import annotations

import logging
import os
import signal
from concurrent import futures

import grpc

import crewai_pb2 as pb
import crewai_pb2_grpc as pb_grpc
from config import CONFIG
from service import CrewOrchestratorServicer

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("crewai.main")


def serve() -> None:
    server = grpc.server(
        futures.ThreadPoolExecutor(max_workers=int(os.getenv("GRPC_WORKERS", "8"))),
        options=[
            ("grpc.max_receive_message_length", 16 * 1024 * 1024),
            ("grpc.max_send_message_length", 16 * 1024 * 1024),
        ],
    )
    pb_grpc.add_CrewOrchestratorServicer_to_server(CrewOrchestratorServicer(), server)

    # gRPC health + reflection (so callers/tooling can discover and probe the service).
    try:
        from grpc_health.v1 import health, health_pb2, health_pb2_grpc

        health_servicer = health.HealthServicer()
        health_pb2_grpc.add_HealthServicer_to_server(health_servicer, server)
        health_servicer.set("", health_pb2.HealthCheckResponse.SERVING)
        health_servicer.set(
            "itorchestra.crewai.v1.CrewOrchestrator", health_pb2.HealthCheckResponse.SERVING
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("grpc health service unavailable: %s", exc)

    try:
        from grpc_reflection.v1alpha import reflection

        names = (
            pb.DESCRIPTOR.services_by_name["CrewOrchestrator"].full_name,
            reflection.SERVICE_NAME,
        )
        reflection.enable_server_reflection(names, server)
    except Exception as exc:  # noqa: BLE001
        log.warning("grpc reflection unavailable: %s", exc)

    bind = f"0.0.0.0:{CONFIG.grpc_port}"
    server.add_insecure_port(bind)  # mTLS is provided by the Linkerd sidecar in-mesh.
    server.start()
    log.info("CrewAI orchestrator listening on %s (version=%s, crewai=%s)",
             bind, CONFIG.service_version, CONFIG.use_crewai)

    stop = futures.ThreadPoolExecutor(max_workers=1)

    def _graceful(signum, _frame):
        log.info("signal %s received; draining...", signum)
        stop.submit(lambda: server.stop(grace=20))

    signal.signal(signal.SIGTERM, _graceful)
    signal.signal(signal.SIGINT, _graceful)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
