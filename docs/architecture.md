# Architecture

## 1 · The two-mouths insight

The design hinges on one observation about sequencers: **they are great at sending sequences and structurally bad at conversations.** A campaign step and a reply-to-a-reply are different machines:

- **Campaigns** (lemlist sequences) — for anything that needs a *new* multi-step touch pattern: the referral campaign, the re-engagement campaign, resuming a paused lead after out-of-office.
- **Conversations** (lemlist inbox API) — for anything that continues an *existing thread*: `POST /inbox/email`, `POST /inbox/linkedin`, `POST /inbox/whatsapp`, sent as the specific sender who owns the thread, threaded by the platform's own mailbox connection.

An early version of this design routed conversation sends through Microsoft Graph (per-sender mail OAuth, manual `In-Reply-To` headers). The inbox API made that entire lane unnecessary — one less OAuth surface per sender, one connection to maintain, and channel parity (LinkedIn and WhatsApp replies work identically to email) for free. Graph survives in exactly one place: calendars (§5).

**Channel-matching rule:** the reply goes out on the channel the prospect used. A LinkedIn reply answered by email reads as "a system noticed you" — the opposite of the intended effect.

## 2 · Ingestion — webhooks trigger, the inbox API supplies truth

Verified against the API spec (not assumed): lemlist activity objects carry **no message body** — just type, lead, campaign, step, timestamp. So ingestion is a two-step:

1. `emailsReplied` / `linkedinReplied` / `whatsappMessageReplied` webhook fires → n8n.
2. `GET /inbox/{contactId}` fetches the **full conversation** — every message, both directions.

Fetching the whole conversation (not just the triggering message) is a feature, not overhead: the classifier sees complete thread context, and the ledger upserts any prior message it somehow missed.

Before anything else runs, the **warmup filter** drops warmup-network traffic (known peer addresses + headers). Warmup emails look exactly like replies to a webhook. Unfiltered, they flood the CRM with ghost activity and poison the ledger.

## 3 · Classification

One Claude call per inbound reply. Input: full conversation, contact + account context from the ledger (tier, persona, signals present, prior routes). Output — a strict JSON contract ([classifier prompt](../examples/classifier_prompt.md)):

```json
{
  "route": 3,
  "confidence": 0.91,
  "language": "cs",
  "entities": {
    "proposed_time": null,
    "referral": null,
    "return_date": null,
    "not_before": "2026-09-01"
  },
  "reasoning": "one sentence, for the ledger"
}
```

The prompt includes **retrieved few-shot examples**: the 5 most similar past replies (vector search over the ledger) *where a human corrected the classification*. This is the cheapest self-improvement mechanism that exists — no fine-tuning, no deployment, and every route-12 click makes next week's classifier slightly better.

Confidence < 0.8 → route 12, unconditionally.

## 4 · The five workflows

One monster workflow is undebuggable and unresumable. The decomposition:

| WF | Trigger | Responsibility |
|---|---|---|
| **WF1 — Router** | lemlist webhook | warmup filter → conversation fetch → classify → universal actions → dispatch to route branch |
| **WF2 — Sender** (sub-workflow) | called by WF1 / WF4 | template + LLM draft within guardrails → humanizer delay → inbox-API send → write-ahead ledger row |
| **WF3 — Scheduler** | daily cron | due follow-ups → **suppression + fresh-signal re-check** → resume lead or enroll in re-engagement campaign |
| **WF4 — Human loop** | Slack interaction webhook | route 12: [Send draft] → WF2 · [Edit] → modal → WF2 · [Close] → ledger. Every click stored as a labeled correction |
| **WF5 — Booking hook** | lemcal webhook | self-serve booking → CRM deal stage + ledger close-out + cancel pending bumps |

Plus two ledger workflows (WF6 reconciliation, WF7 learning) documented in [ledger.md](ledger.md) and [learning-loop.md](learning-loop.md), and WF8 (CRM outcome sync).

**Universal actions** — before any branch, every classified reply gets: lead stopped/paused in **all** campaigns (a prospect who replied must never receive step 3 of a sequence — the single most unprofessional failure in outbound), ledger insert, CRM activity write-back, cooldown entry.

## 5 · Calendar — the one place Graph earns its keep

Fully agentic route 1 means the agent *confirms times*, not just links a booking page. "Can you do Thursday 2pm?" answered with "here's my calendar link" loses bookings — the prospect already did their part.

- **Permissions:** application-level `Calendars.ReadWrite` + `MailboxSettings.Read` (working hours, timezone). **No mail permissions** — messaging belongs to the sequencer.
- **Scoping:** an `ApplicationAccessPolicy` binds the app registration to a security group containing only the sales reps' mailboxes. Without it, app-level calendar permissions reach every mailbox in the tenant — the thing a competent admin rightly refuses.
- **Flow:** prospect proposes a time → `getSchedule` free/busy → free? create event (agenda from the signal context, online-meeting link auto-generated, prospect as attendee). Exchange sends the invitation *from the rep as organizer* — no mail scope needed. Busy? Counter-offer the 2–3 nearest free slots + booking-page fallback. No time proposed? Offer 2 concrete slots (converts better than a bare link) + the link.
- **Race guard:** free/busy is re-checked immediately before event creation; a ≥ 24 h lead-time buffer stops the agent booking a rep into "in 45 minutes."
- **Identity rule:** the invite comes from the sender who owns the thread — the prospect knows *that* name. Rep resolution is thread-sender, never round-robin.

## 6 · State lives in one place

The sequencer is a mirror, never a source of truth. All state — conversation turn counts, route history, cooldowns, scheduled follow-ups, suppression — lives in Postgres ([ledger.md](ledger.md)). This is what makes the system auditable, debuggable, and (via the [learning loop](learning-loop.md)) improvable: you cannot learn from state you don't own.
