# Vigilend — Agent Instructions

**Scope:** This document defines how an AI coding agent (or any contributor)
should operate within the Vigilend repository. It governs *behavior*, not
protocol design decisions. Local project-state documents may provide additional
context when present, but the repository and tracked files remain authoritative.

## 1. Project Summary

Vigilend is a modular, overcollateralized lending protocol composed of:

- Solidity protocol contracts
- A Rust liquidation service
- Security and threat-model documentation

The system is **safety-critical**. Treat the repository — not chat history or
prior session summaries — as the source of truth for current state,
decisions, and behavior.

## 2. Operating Principles (non-negotiable)

1. Prefer explicit assumptions over implicit ones.
2. Prefer conservative accounting over optimistic accounting.
3. Prefer deterministic behavior over convenience.
4. Never claim a result (test, build, fuzz run, invariant, fork test,
   security check) passed unless it was actually executed in the current
   worktree — record the exact command and outcome.
5. Never imply an audit, production deployment, or security guarantee
   without corresponding evidence in the repository.

## 3. Session Startup

Before making any change:

1. Read the local project-state document, such as
   `docs/PROJECT_STATE.md`, when present.
2. Run `git status --short` to see the current worktree state before
   editing.
3. Read the relevant Solidity, Rust, test, and security files — do not
   assume behavior from memory or naming alone.
4. Check recent git history in case a design decision is already recorded.
5. Identify the trust boundaries, assets, actors, and failure modes
   affected before changing protocol behavior.

## 4. General Engineering Rules

- Preserve user changes and unrelated worktree changes; do not revert or
  overwrite work outside the task scope.
- Prefer small, reviewable changes over speculative abstractions.
- Every protocol behavior change requires:
  - Relevant tests (unit and, where applicable, fuzz/invariant).
  - An update to the threat model if the attack surface changes.
- Do not silently change units, precision, signedness, rounding direction,
  token decimals, or liquidation semantics — any such change must be
  explicit, documented, and tested.
- Keep admin, oracle, upgradeability, pause, and emergency powers explicit.
  Do not introduce privileged behavior without documenting its authority
  and failure mode.
- Do not add upgradeability, backwards-compatibility layers, or
  abstractions without a concrete, stated requirement.
- Document assumptions, scope boundaries, known limitations, and
  unresolved risks as they arise — do not defer this to the end of the
  session.

## 5. Solidity & Protocol Work

- Maintain clear separation between: market configuration, risk
  calculations, accounting, token transfers, and liquidation execution.
- Validate all oracle answers for freshness, validity, and expected
  decimals before use.
- Define and document the rounding direction for every conversion; favor
  protocol safety at solvency boundaries.
- Make external calls follow checks-effects-interactions, with explicit
  handling for non-standard ERC-20 behavior (e.g. missing return values,
  fee-on-transfer, reentrant hooks).
- Test at minimum: zero values, maximum values, decimal mismatches, stale
  prices, price crashes, partial liquidations, dust debt, bad debt, and
  repeated accrual.
- Emit events for every state transition needed by off-chain indexing or
  bot operation.
- Extra scrutiny applies to: oracle behavior, decimal conversion,
  rounding, interest accrual, liquidation accounting, authorization,
  reentrancy, and bad-debt handling. Keep the relevant invariants explicit in
  tests and design documentation when available.

## 6. Rust Liquidation Bot Work

- Treat chain data as eventually consistent: handle RPC errors, reorgs,
  duplicate events, stale state, and nonce conflicts explicitly.
- Never submit a liquidation without checking, at submission time: current
  account health, expected proceeds, gas cost, slippage, and net
  profitability.
- Keep private keys and RPC credentials out of source control.
- Make retry logic bounded and observable — no unbounded submission loops.

## 7. Verification

Use the narrowest relevant command while iterating; run the full set before
marking a change ready for review. Record actual results — including
failures — in the local project-state document when present, or in the change
handoff if the state document is not tracked.

| Purpose | Command |
|---|---|
| Solidity build | `forge build` |
| Unit & fuzz tests | `forge test` |
| Invariant tests | `forge test --match-path test/invariant/**` |
| Fork tests | `forge test --match-path test/fork/**` |
| Formatting check | `forge fmt --check` |
| Rust tests | `cargo test` |
| Rust lint | `cargo clippy -- -D warnings` |
| Rust formatting | `cargo fmt --check` |

Do not report coverage, gas, fork, fuzz, invariant, or security results
unless the corresponding command was actually run in the current worktree.

## 8. Session Shutdown

Before ending a substantial task, update the local project-state document when
present, or include the following in the change handoff:

- What changed (affected files).
- Verification commands run and their actual results.
- Open risks or decisions introduced or resolved.
- The next concrete task.

Keep the update concise and factual. Use git history, not this document,
for implementation detail.
