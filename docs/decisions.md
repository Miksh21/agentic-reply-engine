# Architecture Decision Records

Short-form ADRs, including the ones that were wrong first. Ordered by how much each decision shaped the system.

---

## ADR-1 · Sequencer inbox API for conversations, not direct mail APIs

**First design:** in-thread replies via Microsoft Graph — per-sender mail OAuth, manual `In-Reply-To` headers, Graph mail-read for ingestion.

**Revised after reading the actual API spec:** the sequencer exposes a full inbox API — send email / LinkedIn / WhatsApp within an existing conversation as a specific sender, read full conversations, stage drafts, label threads.

**Consequences:** deleted an entire OAuth surface (per-sender mail consent), gained channel parity for free (LinkedIn and WhatsApp replies work identically), and threading is the platform's problem. Also unified the go-live gate: everything messaging-related now depends on one thing — senders connected in the sequencer.

**Lesson worth keeping:** verify platform capabilities against the current spec before designing around their absence. The first design was built on a stale mental model of the API.

## ADR-2 · Graph scoped to calendars only

Application-level `Calendars.ReadWrite` + `MailboxSettings.Read`, **no mail permissions**, bound by an `ApplicationAccessPolicy` to only the reps' mailboxes.

**Why:** invitations send from Exchange automatically when an event has attendees — mail scope is unnecessary. And an unscoped app-level calendar permission reaches every mailbox in the tenant, which is both a real risk and the kind of request that (rightly) stalls in admin review. Minimal scope is also the fastest path through consent.

## ADR-3 · Bodies materialized in the ledger, never fetched on demand

Activity events carry no message bodies (verified). Campaign copy is rendered at enroll time; agent sends are write-ahead logged; inbound bodies come from the conversation fetch; a nightly reconciliation diffs the ledger against the platform.

**Why:** an audit trail that says "an email was sent" is not an audit trail. And webhooks are lossy — without reconciliation the ledger is a cache, not a record.

## ADR-4 · 12 routes, not a free-form agent

The classifier picks from a **closed taxonomy** with per-route playbooks, rather than letting an agent decide open-endedly what to do.

**Why:** a closed set is testable (classification accuracy is measurable), auditable (route distributions are comparable week over week), and learnable (corrections are labels). A free-form agent is none of these. The taxonomy came from a reply-handling knowledge base built across campaigns — 5 triage categories × 4 intent tiers × 6 objection types, deduplicated to 12 terminals.

## ADR-5 · The human gate is a route, not a review step

The predecessor design ([duvo-reply-intelligence](https://github.com/Miksh21/duvo-reply-intelligence)) put a human in front of **every send** — the right call for that context (someone else's brand, first deployment, no accumulated trust). This engine moves the gate: 11 routes fully autonomous, 1 route human — plus the two-turn and confidence escapes that *feed* that route.

**Why the move is justified here and wasn't there:** the guardrails plus the ledger change the risk calculus. Bounded playbooks, deterministic gates at every send, and a full audit trail mean an error is contained and traceable. Trust in automation should be earned by architecture, not asserted by enthusiasm — this is the same system *after* earning it.

## ADR-6 · One conversation brain (WF2), many callers

Every outbound word — routes 1–9, human-approved route-12 sends, bumps — flows through a single sender sub-workflow that owns template constraints, language guardrails, the humanizer, suppression re-check, and write-ahead logging.

**Why:** guardrails enforced in one place are guardrails; guardrails copy-pasted into nine branches are suggestions.

## ADR-7 · Tiered autonomy in the learning loop

Numeric, bounded, reversible changes (variant weights, timings, few-shot pool) auto-apply. Compounding changes (new copy, targeting shifts, large weight moves) stage to a weekly one-click digest.

**Why:** a self-rewriting copy loop with no floor drifts the voice of the whole operation in weeks, and every later variant inherits the drift. The digest costs ~3 minutes and reuses the route-12 interaction pattern. See [learning-loop.md](learning-loop.md).

## ADR-8 · Postgres as the only state

Turn counts, cooldowns, schedules, suppression, experiments — all in the warehouse; the sequencer and CRM are mirrors.

**Why:** inherited from the sibling repo and non-negotiable: you cannot audit, debug, or learn from state you don't own. Every incident post-mortem in the predecessor systems traced to state living in a tool that couldn't be queried.
