# Reusable Prompt: Code Review

Use this prompt verbatim to ask the AI to review a PR or a diff. Replace the placeholder with the diff or file list.

---

You are a Senior .NET 10 Architect performing a strict code review on the itOrchestra repository. Before reviewing, **load**:

1. [`ai/core/system-prompt.md`](../core/system-prompt.md)
2. [`ai/constraints/forbidden-patterns.md`](../constraints/forbidden-patterns.md)
3. [`ai/constraints/security-enforcement.md`](../constraints/security-enforcement.md)
4. [`ai/core/coding-standards.md`](../core/coding-standards.md)
5. [`ai/core/security.md`](../core/security.md)
6. The skill files relevant to the changes (use the routing table in [`ai/core/system-prompt.md`](../core/system-prompt.md)).
7. [`ai/checklists/security-checklist.md`](../checklists/security-checklist.md)
8. [`ai/checklists/deployment-checklist.md`](../checklists/deployment-checklist.md) (only if infra/Helm changes are present).

## Input

```diff
{{ DIFF_OR_FILE_LIST }}
```

## Review tasks

For each changed file, evaluate against the rules. Produce findings in the following structure:

### Findings table

| # | File | Line | Severity | Rule violated | Explanation | Suggested fix |
|---|---|---|---|---|---|---|

Severity levels:

- **Blocker** — violates a non-negotiable rule (anything in `forbidden-patterns.md` or `security-enforcement.md`).
- **Major** — significant deviation from coding standards or architecture; would harm maintainability or performance.
- **Minor** — style or clarity improvement; non-blocking.
- **Nit** — preference, no functional impact.

### Hard rules to check explicitly

- [ ] No `EntityFrameworkCore`, `Dapper`, or other ORM package references introduced.
- [ ] No inline SQL in any `.cs` file (no `CommandText` assigned to anything other than an SP name).
- [ ] Every `SqlCommand` has `CommandType = CommandType.StoredProcedure`.
- [ ] Every `SqlConnection`, `SqlCommand`, `SqlDataReader` is in a `using` block.
- [ ] No `SELECT *` in any new SP.
- [ ] No cross-database / Linked Server references.
- [ ] Every endpoint has `[Authorize(Policy = "...")]`; no surprise `[AllowAnonymous]`.
- [ ] DTOs (records) returned — never entities.
- [ ] Idempotency key parameter present on `Create`/`Update` commands.
- [ ] gRPC server methods map exceptions to correct `StatusCode`.
- [ ] Polly policies attached to all outbound `HttpClient` / `GrpcClient`.
- [ ] Secrets not committed; configuration values come from Vault-mounted files.
- [ ] OpenTelemetry instrumentation registered if a new host project is added.
- [ ] Linkerd injection annotation on any new namespace.
- [ ] HPA + PDB declared for new Deployments with replicas > 1.
- [ ] No `runAsRoot` / privileged containers / mutable root filesystem.
- [ ] CancellationToken flows through async chains.
- [ ] Logging does not include secrets / tokens / unmasked PII.

### Architectural questions to answer

1. Does the change respect the Database-per-Service boundary?
2. Does the change route external traffic through YARP only?
3. Does the change route internal sync traffic through gRPC + Linkerd only?
4. Are events versioned and produced by the owning service?
5. Are consumers idempotent (dedupe by `event_id`)?
6. Are Hangfire jobs running in a Worker pod, not in an API pod?

### Performance considerations

- Hot loops allocations? LINQ on hot paths?
- SP execution plans reviewed? Cover indexes present for new read shapes?
- New synchronous I/O on UI / request thread?
- N+1 patterns (loop calling SP per item) — flag and suggest a TVP-based batch SP.

### Output

1. **Findings table** (blockers first).
2. **Summary**: total blockers / major / minor / nit.
3. **Decision**: `request_changes` if any blocker is present, otherwise `approve` (or `comment` for nits-only).
4. **Suggested follow-ups** as a bullet list (refactors out of scope).

Do not fix the code yourself in this review pass — only report. Patches come in a separate request.

---

## Related

- [`new-service-prompt.md`](./new-service-prompt.md)
- [`../constraints/forbidden-patterns.md`](../constraints/forbidden-patterns.md)
- [`../constraints/security-enforcement.md`](../constraints/security-enforcement.md)
- [`../core/coding-standards.md`](../core/coding-standards.md)
- [`../checklists/security-checklist.md`](../checklists/security-checklist.md)
