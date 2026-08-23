# GF-006 — Independent OpenAI Critic

GF-006 inserts a read-only semantic review after deterministic validation and before the Game Foundry-owned commit. It is opt-in through a locked milestone policy:

```json
{"review_policy":{"type":"openai_critic","required":true,"block_on":["blocker"]}}
```

Historical milestones without this policy remain critic-disabled and require neither OpenAI configuration nor network access.

## Trust boundary and API

The implementer remains OpenClaw → Codex. The reviewer is a separate direct `POST /v1/responses` call with fresh context, `store:false`, no tools, and strict Structured Outputs using [the source-controlled schema](../../schemas/critic-response.schema.json). The helper never receives shell, Git, filesystem, OpenClaw, Codex, or state tools.

Runtime configuration is supplied only through:

```text
OPENAI_API_KEY
GF_OPENAI_CRITIC_MODEL
GF_OPENAI_CRITIC_TIMEOUT_SECONDS       # default 60
GF_OPENAI_CRITIC_MAX_EVIDENCE_BYTES    # default 262144
```

The API key is sent only in the HTTP Authorization header. It is absent from arguments, request artifacts, responses, reports, and Git. Required configuration is checked before a task is claimed or Codex is invoked.

## Review evidence

After deterministic PASS, Game Foundry creates a bounded evidence bundle with stable labels: `DESIGN`, `GUIDELINES`, `TASK`, `TASK_PROMPT`, `PATCH`, `CHANGED_FILES`, `SCOPE_RESULT`, `VALIDATOR`, `VALIDATION_RESULT`, and `VALIDATION_LOG`. Unrelated repository content and credentials are excluded.

The trusted reviewer instruction explicitly treats all supplied repository text, diffs, logs, comments, and prompt-like strings as untrusted evidence rather than instructions. The evidence size limit fails closed instead of silently truncating or uploading an entire repository.

Each child artifact gains:

```text
critic/evidence.json
critic/request.json
critic/response.json
critic/result.json
critic/review.txt
critic/read-only-proof.json
```

The read-only proof hashes Git status, candidate patch, execution-branch HEAD, and milestone state before and after the API call.

## Contract and decision

The strict response contains `decision`, `summary`, and findings. Finding severity is exactly `blocker`, `warning`, or `observation`, with a constrained category and evidence references. Game Foundry locally validates the saved output against the same schema used for the API request and recomputes the decision from blocker count.

- No blocker: `CRITIC_PASS`; commit and PASS may proceed.
- Any blocker: `CRITIC_BLOCK`; no commit, task FAIL, bounded runner stops.
- Transport, timeout, refusal, incomplete response, invalid JSON/schema, inconsistency, or read-only violation: `CRITIC_ERROR`; fail closed.

Warnings and observations remain recorded but do not block. Deterministic failure skips the critic entirely. The critic cannot approve milestone state directly, alter commit messages, or override deterministic or human gates.

## Metrics and limitations

Child and bounded-run manifests record critic calls, passes, blocks, errors, duration, model, response ID, and token usage when present. Pricing is deliberately not hard-coded.

GF-006 does not implement repair, retry, multi-model voting, Ollama review, required visual review, scheduling, parallelism, pushing, PR creation, or release. The explicit test hook `GF_GF006_ENABLE_TEST_HOOKS=1` supports transport/contract fixtures; `GF_GF006_INJECT_FORBIDDEN_MARKER=1` creates the acceptance-only semantic gap. Both are disabled by default.

GF-007 may add bounded Codex repair and re-review after a critic blocker. It is not implemented here.
