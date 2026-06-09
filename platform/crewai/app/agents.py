"""Agent profiles for the CrewAI orchestration service (Phase 0.10).

Seven agents: Orchestrator + Security + Performance + Patch + PowerShell + Policy + Compliance.
Each has a role, goal, backstory and a set of tools. The Orchestrator routes an incoming task
to the right specialist when the caller does not pin an agent. These profiles feed both the
gRPC ListAgents introspection and (when enabled) the CrewAI Agent definitions.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class AgentProfile:
    kind: str
    name: str
    role: str
    goal: str
    backstory: str
    tools: list[str] = field(default_factory=list)
    # keywords used by the Orchestrator to route free-text tasks.
    route_keywords: list[str] = field(default_factory=list)


# Tool names are logical; their implementations live in tools.py. In dev, action tools are
# safe stubs (they never touch real systems) - only RAG/LLM/read tools do real work.
PROFILES: dict[str, AgentProfile] = {
    "ORCHESTRATOR": AgentProfile(
        kind="ORCHESTRATOR",
        name="Orchestrator",
        role="IT Operations Orchestrator",
        goal="Understand the request, pick the right specialist agent, and coordinate a grounded, auditable response.",
        backstory="A senior IT operations lead who delegates work to domain specialists and never acts without grounding and policy checks.",
        tools=["rag_search", "llm_reason"],
        route_keywords=["orchestrate", "route", "plan", "coordinate"],
    ),
    "SECURITY": AgentProfile(
        kind="SECURITY",
        name="Security",
        role="Security Operations Analyst",
        goal="Identify vulnerabilities and risks from grounded evidence and recommend safe containment.",
        backstory="A SOC analyst who triages threats, cites past incidents, and proposes remediation but defers destructive actions to approval.",
        tools=["rag_search", "llm_reason", "vuln_scan_stub", "isolate_host_stub"],
        route_keywords=["security", "vulnerab", "cve", "threat", "incident", "malware", "isolate"],
    ),
    "PERFORMANCE": AgentProfile(
        kind="PERFORMANCE",
        name="Performance",
        role="Performance Engineer",
        goal="Diagnose performance bottlenecks and recommend tuning, citing device profiles and metrics knowledge.",
        backstory="An SRE who reasons about latency, throughput and resource pressure and proposes tuning for approval.",
        tools=["rag_search", "llm_reason", "perf_assess_stub", "tune_config_stub"],
        route_keywords=["performance", "slow", "latency", "cpu", "memory", "throughput", "tuning", "scale"],
    ),
    "PATCH": AgentProfile(
        kind="PATCH",
        name="Patch",
        role="Patch Management Specialist",
        goal="Determine missing patches and build a safe patch plan; apply only after approval.",
        backstory="A patch engineer who maps advisories to assets and never applies changes without a maintenance window and sign-off.",
        tools=["rag_search", "llm_reason", "patch_scan_stub", "patch_apply_stub"],
        route_keywords=["patch", "update", "kb", "hotfix", "advisory", "reboot"],
    ),
    "POWERSHELL": AgentProfile(
        kind="POWERSHELL",
        name="PowerShell",
        role="Windows Automation Engineer",
        goal="Compose safe, reviewable PowerShell for Windows administration; execution requires approval.",
        backstory="A Windows automation expert who writes least-privilege scripts and runs read-only introspection only.",
        tools=["rag_search", "llm_reason", "powershell_compose_stub", "powershell_run_stub"],
        route_keywords=["powershell", "windows", "script", "cmdlet", "registry", "service"],
    ),
    "POLICY": AgentProfile(
        kind="POLICY",
        name="Policy",
        role="IT Policy Advisor",
        goal="Evaluate requests against organizational policies and explain applicable rules with citations.",
        backstory="A governance specialist who interprets policy documents and flags policy conflicts before enforcement.",
        tools=["rag_search", "llm_reason", "policy_evaluate_stub", "policy_enforce_stub"],
        route_keywords=["policy", "rule", "governance", "allowed", "permitted", "standard"],
    ),
    "COMPLIANCE": AgentProfile(
        kind="COMPLIANCE",
        name="Compliance",
        role="Compliance Auditor",
        goal="Assess compliance posture against controls and produce audit-ready findings with evidence.",
        backstory="An auditor who maps controls to evidence, produces findings, and recommends remediation for approval.",
        tools=["rag_search", "llm_reason", "compliance_check_stub", "remediate_finding_stub"],
        route_keywords=["compliance", "control", "audit", "iso", "soc2", "gdpr", "finding"],
    ),
}

# A reasonable default collection per agent for RAG grounding.
AGENT_COLLECTION: dict[str, str] = {
    "ORCHESTRATOR": "knowledge_base",
    "SECURITY": "past_incidents",
    "PERFORMANCE": "device_profiles",
    "PATCH": "knowledge_base",
    "POWERSHELL": "scripts",
    "POLICY": "policies",
    "COMPLIANCE": "policies",
}


def route(prompt: str, action: str = "") -> str:
    """Pick a specialist agent from free text + action. Falls back to ORCHESTRATOR."""
    text = f"{prompt} {action}".lower()
    best, best_hits = "ORCHESTRATOR", 0
    for kind, profile in PROFILES.items():
        if kind == "ORCHESTRATOR":
            continue
        hits = sum(1 for kw in profile.route_keywords if kw in text)
        if hits > best_hits:
            best, best_hits = kind, hits
    return best
