"""Reasoning layer (Phase 0.10).

Turns an agent profile + RAG context + task into a grounded recommendation. When USE_CREWAI is
on, this drives a single-agent CrewAI crew against the local LLM (Ollama, OpenAI-compatible);
on any import/runtime error (or when disabled) it falls back to a direct LLM call so the gRPC
service stays responsive. Both paths produce the same kind of text rationale.
"""
from __future__ import annotations

import logging

from agents import AgentProfile
from config import CONFIG
import tools

log = logging.getLogger("crewai.crew")


def _system_prompt(profile: AgentProfile) -> str:
    return (
        f"You are the {profile.name} agent ({profile.role}).\n"
        f"Goal: {profile.goal}\n"
        f"Backstory: {profile.backstory}\n"
        "Ground every claim in the provided CONTEXT when available. If context is empty, say so "
        "and reason cautiously. Never invent system state. Keep the answer concise and actionable. "
        "If the task would change a system, describe the plan but DO NOT assume it was executed."
    )


def _user_prompt(prompt: str, context: str) -> str:
    ctx = context.strip() or "(no grounded context found)"
    return f"CONTEXT:\n{ctx}\n\nTASK:\n{prompt}\n\nProvide your recommendation:"


def _direct(profile: AgentProfile, prompt: str, context: str) -> str:
    return tools.llm_chat(_system_prompt(profile), _user_prompt(prompt, context))


def _crewai(profile: AgentProfile, prompt: str, context: str) -> str:
    # Lazy import so a missing/incompatible crewai never breaks module import or the fallback.
    from crewai import Agent, Crew, Task, LLM  # type: ignore

    llm = LLM(
        model=f"openai/{CONFIG.chat_model}",
        base_url=CONFIG.llm_base_url,
        api_key="not-needed",
        timeout=CONFIG.llm_timeout_s,
    )
    agent = Agent(
        role=profile.role,
        goal=profile.goal,
        backstory=profile.backstory,
        llm=llm,
        allow_delegation=False,
        verbose=False,
    )
    task = Task(
        description=_user_prompt(prompt, context),
        expected_output="A concise, grounded, actionable recommendation.",
        agent=agent,
    )
    crew = Crew(agents=[agent], tasks=[task], verbose=False)
    return str(crew.kickoff()).strip()


def reason(profile: AgentProfile, prompt: str, context: str) -> str:
    if CONFIG.use_crewai:
        try:
            return _crewai(profile, prompt, context)
        except Exception as exc:  # noqa: BLE001 - degrade gracefully to direct LLM
            log.warning("CrewAI path failed (%s); falling back to direct LLM", exc)
    return _direct(profile, prompt, context)
