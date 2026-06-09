"""Per-agent permissions matrix (Phase 0.10).

Defines, for every agent, which actions may be executed automatically, which require human
approval, and which are denied outright. This is the safety boundary between "AI suggests" and
"AI acts". Resolution order: exact action -> verb-prefix (``patch.*``) -> agent default ->
global default. The global default is APPROVAL (fail-safe: never auto-run an unknown action).
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Policy(str, Enum):
    AUTO = "auto"  # safe / read-only: execute and audit
    APPROVAL = "approval"  # mutating / sensitive: park as PENDING_APPROVAL
    DENY = "deny"  # never permitted


@dataclass(frozen=True)
class Evaluation:
    policy: Policy
    auto_allowed: bool
    requires_approval: bool
    denied: bool


GLOBAL_DEFAULT = Policy.APPROVAL

# Read-only verbs are advisory everywhere; mutating verbs always need a human in dev.
_COMMON: dict[str, Policy] = {
    "read.kb": Policy.AUTO,
    "query.rag": Policy.AUTO,
    "analyze": Policy.AUTO,
    "assess": Policy.AUTO,
    "recommend": Policy.AUTO,
    "report": Policy.AUTO,
}

# action (or verb prefix) -> policy, per agent. Defaults to APPROVAL for anything mutating.
AGENT_PERMISSIONS: dict[str, dict[str, Policy]] = {
    "ORCHESTRATOR": {
        **_COMMON,
        "route": Policy.AUTO,
        "plan": Policy.AUTO,
    },
    "SECURITY": {
        **_COMMON,
        "scan.vuln": Policy.AUTO,  # read-only scan -> advisory
        "assess.risk": Policy.AUTO,
        "isolate.host": Policy.APPROVAL,  # mutating containment
        "remediate": Policy.APPROVAL,
        "block.ip": Policy.APPROVAL,
    },
    "PERFORMANCE": {
        **_COMMON,
        "assess.performance": Policy.AUTO,
        "tune.config": Policy.APPROVAL,
        "scale": Policy.APPROVAL,
        "restart.service": Policy.APPROVAL,
    },
    "PATCH": {
        **_COMMON,
        "scan.patches": Policy.AUTO,  # report missing patches
        "patch.plan": Policy.AUTO,
        "patch.apply": Policy.APPROVAL,  # changes the system
        "reboot": Policy.APPROVAL,
    },
    "POWERSHELL": {
        **_COMMON,
        "powershell.read": Policy.AUTO,  # read-only Get-* style introspection (stub)
        "powershell.run": Policy.APPROVAL,
        "config.change": Policy.APPROVAL,
    },
    "POLICY": {
        **_COMMON,
        "evaluate.policy": Policy.AUTO,
        "policy.enforce": Policy.APPROVAL,
    },
    "COMPLIANCE": {
        **_COMMON,
        "check.compliance": Policy.AUTO,
        "audit.report": Policy.AUTO,
        "remediate.finding": Policy.APPROVAL,
    },
}

AGENT_DEFAULT: dict[str, Policy] = {k: Policy.APPROVAL for k in AGENT_PERMISSIONS}


def evaluate(agent_kind: str, action: str) -> Evaluation:
    """Resolve the policy for (agent, action)."""
    action = (action or "").strip().lower()
    table = AGENT_PERMISSIONS.get(agent_kind, {})

    policy: Policy | None = None
    if action in table:
        policy = table[action]
    else:
        verb = action.split(".", 1)[0] if action else ""
        # verb-level match: e.g. action "patch.apply.kb5" -> "patch.apply" -> "patch"
        for key, val in table.items():
            if action.startswith(key + ".") or key == verb:
                policy = val
                break
    if policy is None:
        policy = AGENT_DEFAULT.get(agent_kind, GLOBAL_DEFAULT)

    return Evaluation(
        policy=policy,
        auto_allowed=policy == Policy.AUTO,
        requires_approval=policy == Policy.APPROVAL,
        denied=policy == Policy.DENY,
    )


def matrix_for(agent_kind: str) -> list[tuple[str, bool, bool]]:
    """(action, auto_allowed, denied) tuples for ListAgents introspection."""
    out: list[tuple[str, bool, bool]] = []
    for action, policy in AGENT_PERMISSIONS.get(agent_kind, {}).items():
        out.append((action, policy == Policy.AUTO, policy == Policy.DENY))
    return out
