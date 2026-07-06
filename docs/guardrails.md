# Guardrails

"Fully agentic" survives contact with real prospects only because of these six. Each exists because of a specific failure mode — three of them observed, three anticipated.

## 1 · The two-turn rule

The agent holds **at most two conversational turns per thread**. The third inbound message in any thread auto-escalates to route 12, regardless of classification confidence.

**Failure mode prevented:** an agent arguing with a prospect. Multi-turn LLM conversations drift — the model starts negotiating, over-explaining, or agreeing to things. Two turns covers the legitimate agentic conversations (qualify → book; probe → close); anything longer means the situation has left the playbook, which is the definition of route 12.

## 2 · The confidence gate

Classification confidence < 0.8 → route 12. No exceptions, no "but the entities look clean."

**Failure mode prevented:** the reputational worst case — a hard-no misrouted as nurture, answered with a cheerful qualifying question. One of those screenshot-ed on LinkedIn costs more than a month of route-12 clicks.

## 3 · The warmup filter

Warmup-network traffic is excluded **before** classification — by known peer addresses and headers — not detected after.

**Failure mode prevented (observed):** warmup emails are engineered to look like real correspondence, which means they also look like real replies to a webhook. Unfiltered, they flood the CRM with ghost activity, poison the ledger, and burn classifier calls on synthetic mail. This one is a landmine because nothing *errors* — the system just quietly fills with garbage. The original incident (~10k junk CRM records in one flood, weeks of cleanup) is documented in the sibling repo: [consolidation.md](https://github.com/Miksh21/signal-driven-outbound/blob/main/docs/consolidation.md).

## 4 · The humanizer

Every agent send: randomized 5–20 minute delay, business hours only (local to the prospect), never weekends.

**Failure mode prevented:** a reply arriving 40 seconds after the prospect hit send reads as a bot even when the copy is perfect. Speed matters (route 1 has an SLA), but *instant* is the one speed a human never exhibits.

## 5 · Suppression re-check at every send point

The suppression gate runs at classification time **and again at every deferred send**: scheduled follow-ups, re-engagement enrollments, referral enrollments, OOO resumes.

**Failure mode prevented:** time passes between decision and execution. A route-3 follow-up scheduled in June for September fires into an account that hard-no'd a *different* sender in July. Gate-at-decision-only architectures leak exactly here; the gate must sit at the send, because the send is what the prospect experiences.

## 6 · Language guardrails (the Czech lesson)

All drafting happens inside template constraints — the LLM fills slots, it doesn't freestyle — and **morphology is the LLM's job, never regex**. For Czech specifically:

- **Vocative case** — addressing someone by name declines it (*pan Novák* → *"pane Nováku"*), with palatalization rules that break naive suffix logic (*Luděk* → *"Luďku"*, not *"Luděku"*). A regex will get common names right and exactly the uncommon ones wrong — the people most likely to notice.
- **Gender-matched verb forms** — Czech first-person past tense encodes the speaker's gender (*"rád bych"* / *"ráda bych"*). Drafts resolve against the **sender's** registered gender, per message.
- **Injected nouns decline to their grammatical case** — a role dropped into a sentence template must take the case the sentence demands, not the nominative it was stored in.
- **No em-dashes, human company names** (legal suffixes stripped) — the small tells that separate native copy from translated automation.

**Failure mode prevented:** in a smaller language market, prospects have seen far less automation than in English — and spot it far faster. One wrong declension outs the entire operation as a bot, retroactively, for every message it ever sent.

---

## The pattern behind all six

Each guardrail is a cheap deterministic check wrapped around an expensive probabilistic system. None of them makes the agent smarter; all of them cap the cost of it being wrong. That asymmetry — clever core, boring armor — is the whole trick of running LLMs against live counterparties.
