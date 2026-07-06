# The Message Ledger

## Principle: no message exists unless it's a row

The system of record is Postgres, not the sequencer. The rule extends the sibling repo's warehouse principle to its conclusion: **the ledger knows every word before and after it's sent.**

- Outbound **campaign** copy is rendered and stored **at enroll time** — the engine built the campaign and owns the variables, so it knows exactly what the sequencer will send before the sequencer sends it.
- Outbound **agent** replies are **write-ahead logged** — the row is inserted *before* the send API call. A failed send is still an auditable event.
- **Inbound** replies land via the conversation fetch, which upserts the full thread — self-healing for any previously missed message.

Why this matters: verified against the API spec, sequencer activity events carry **no message body** (type, lead, campaign, step, timestamp — that's all). If you don't materialize copy yourself, your audit trail is "an email was sent," not "*this* email was sent."

## Capture paths

| Message type | Body source | Trigger |
|---|---|---|
| Campaign send | rendered at enroll (`status = rendered`); the sent-webhook flips to `sent` + stamps the activity id | enrollment + webhook |
| Agent reply (routes 1–9) | write-ahead insert, then inbox-API send | WF2 |
| Human-approved reply (12) | same path, `drafted_by = 'human'` | WF4 → WF2 |
| Inbound reply | full-conversation fetch → upsert | WF1 |
| Opens / clicks / bounces / LinkedIn events | status + event updates on existing rows (no body exists) | webhooks |
| **Anything missed** | nightly reconciliation | WF6 |

## Reconciliation — what makes it audit-grade

Webhooks are lossy. The orchestrator restarts, a deploy overlaps a burst of activity, and there's a silent hole in the ledger that surfaces three weeks later as "why does the CRM show a reply we never processed?"

**WF6 (nightly):** page through the activities API since the last watermark + sweep active conversations via the inbox API, diff against the ledger, log every discrepancy, backfill bodies. The same job performs the initial historical backfill on day one. A ledger without reconciliation is a cache; with it, it's a system of record.

## Schema

Full DDL in [`examples/schema.sql`](../examples/schema.sql). The shape:

- **`messages`** — every message, both directions: channel, sender, campaign/step (null for agent replies), subject, body, status, inbound classification (route, confidence, extracted entities), `drafted_by` (template | agent | human — the audit column), timestamps, FTS vector, embedding.
- **`conversations`** — thread state: turn count (feeds the two-turn rule), last route, channel mix.
- **`decisions`** — every agent choice with **inputs frozen**: what the score was, which signals were present, which prompt version ran, what came out. The learning loop's raw material and the audit answer to "why did the system do that?"
- **`outcomes`** — what actually happened, synced from the CRM and the booking tool: meeting booked, showed, deal created/won, closed soft, unsubscribed.
- **`variants`** — copy experiments with send/reply/positive-reply counts and sampling weights.
- **`learnings`** — extracted insights with evidence pointers and their autonomy tier (auto-applied vs. staged).
- Plus the shared tables with the outbound engine: `signals`, `suppression`, `follow_ups`, `senders`, `reply_templates`, `assets`.

## Plain-English search

Two search modes, because audits need both:

- **Lexical** — generated `tsvector` column (language-appropriate config): *"find the exact message mentioning 'within 14 days'"*.
- **Semantic** — pgvector embedding per message (embedded on insert; small-model embeddings cost fractions of a cent per thousand messages): *"what did we tell manufacturing companies who said they use a competitor?"*

One RPC (`search_messages`) fuses both with reciprocal-rank fusion, with filters on direction / channel / campaign / route / date. On top of that, an LLM agent with database access (in practice: a Claude Code session with the schema documented in a skill) turns plain-English audit questions into queries — *"show me every timing objection from 50–200-employee companies in Q3, and what we replied"* — with no dashboard build required. Views (`v_conversation_timeline`, `v_route_performance`, `v_source_quality`) cover the recurring audit shapes.

## What the ledger unlocks

1. **Audits in one tool** — every touch, every direction, every channel, one query surface.
2. **The learning loop** — you cannot learn from state you don't own ([learning-loop.md](learning-loop.md)).
3. **Compliance posture** — suppression decisions and their timestamps are provable.
4. **List forensics** — bounces trace to the enrichment source that produced the address (the sibling repo's list-decay diagnosis, now with receipts).
