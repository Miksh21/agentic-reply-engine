# The 12 Routes

Reply handling collapses into a 3-layer taxonomy — triage category → meeting-intent tier → objection type. Deduplicating the overlaps ("not interested" and "wrong person" appear in two layers; a soft close *is* a timing objection) yields **12 terminal routes**. Every inbound reply lands in exactly one.

Universal actions precede every route: lead stopped in all campaigns, ledger write, CRM write-back, cooldown entry.

---

## Route 1 — Book it now

**Trigger examples:** *"Can you do Thursday 2pm?"* · *"What does pricing look like?"* · *"Send over a case study for companies our size"* · forwards you to a colleague with intent.

**Action:** free/busy check on the thread's sender → time works: calendar invite created (agenda references the signal that started the conversation) + in-thread confirmation. Time busy: counter-offer 2–3 nearest free slots + booking link. No time given: propose 2 concrete slots + link. CRM deal created at "meeting proposed". Slack FYI to the rep (informational, not approval).

**Window:** send within 5–20 min (randomized, business hours). No booking after 3 business days → one bump with 2 fresh concrete slots. Booked → WF5 closes the loop.

**Asset needed:** booking page per sender; calendar access ([architecture §5](architecture.md)).

---

## Route 2 — Nurture

**Trigger examples:** *"Interesting, tell me more"* · *"How does this work exactly?"* · engages with the signal reference (*"yes, we did just post three engineering roles"*).

**Action:** ONE qualifying question in-thread. Never a pitch, never an attachment — "tell me more" answered with a deck is a conversation killer. State → `nurture_awaiting`.

**Window:** their next reply re-enters the router (often upgrades to route 1). Silence 4 business days → one bump. Silence again → route 3 treatment (soft close). **Two-turn rule applies** — see [guardrails](guardrails.md).

---

## Route 3 — Timing / soft close

**Trigger examples:** *"Not right now, maybe after summer"* · *"We're mid-reorg, try me in Q4"* · *"Swamped this quarter."*

**Action:** warm confirmation of *their* timeline (echoing their words, not a generic "I'll circle back"). Extracted date → `follow_ups` row (stated month, else +90 days).

**Window:** when due, the scheduler **re-checks suppression and fresh signals first**, then enrolls in the re-engagement campaign whose first step references the original conversation. One soft-close reply maximum — if the door-open response gets nothing, close; don't stack.

**Asset needed:** re-engagement campaign (2 steps) with a `prior_context` variable materialized from the ledger at enroll time.

---

## Route 4 — Hard no / unsubscribe

**Trigger examples:** *"We're all set, please remove me"* · *"Unsubscribe"* · anything with legal flavor.

**Action:** **no reply at all** — answering an unsubscribe request is worse than silence. Sequencer unsubscribe list + ledger suppression: contact permanent, account 12-month cooldown. CRM flagged.

**Window:** terminal. The suppression gate makes re-contact structurally impossible — including by *other* senders and *future* campaigns.

---

## Route 5 — Soft not-interested

**Trigger examples:** *"Thanks, not for us"* · *"We'll pass"* — rejection without hostility or context.

**Action:** two sentences — one validating their call, one planting a seed for later. No pitch, no "just in case", nothing to respond to. State `closed_soft`, 9-month cooldown, account stays in signal-watch.

**Window:** terminal for outreach. **Aggregate signal:** a campaign whose route-5 rate spikes has a *targeting* problem, not a copy problem — this feeds the weekly report, not another copy iteration.

---

## Route 6 — Incumbent

**Trigger examples:** *"We already work with an agency"* · *"We have this covered internally."*

**Action:** one question probing whether the incumbent actually delivers (*"Out of interest — are they filling your technical roles within your timelines?"*). Never attack the incumbent; it reads as defensive and forces them to defend their past decision.

**Window:** engagement → re-enters as route 2. Silence 5 business days → close, 6-month cooldown.

---

## Route 7 — Send more info

**Trigger examples:** *"Can you send something over?"* · *"Do you have materials I could look at?"*

**Action:** one short paragraph + **one** tracked link + one qualifying question. The link-plus-question structure is the filter: a genuine prospect clicks and answers; a polite brush-off does neither, and now you know which it was. Never a deck, never three attachments.

**Window:** click but no reply → bump day 3. No click → close day 7, 6-month cooldown.

**Asset needed:** one link-able proof asset per segment (case-study page or one-pager). *If the asset doesn't exist yet, this route falls through to route 12 — an automated route without its asset is worse than a human.*

---

## Route 8 — Referral

**Trigger examples:** *"That's not me — talk to Petra, our Head of Recruitment"* · *"Try our HR department."*

**Action:** two parallel branches. (a) Thank the referrer in-thread — one sentence. (b) Resolve the referred person: full name + company → email waterfall → suppression check → enroll in the **referral campaign** with `referrer_name` and `context_snippet` variables. Role only ("our HR") → find the role-holder at the domain, or ask the referrer one clarifying question.

**Window:** referred person enrolled **next business day** — the referrer's mental "expect an email from them" should land first. Referrer marked `closed_won_referral` with a permanent goodwill flag.

**Asset needed:** referral campaign (2 steps: warm intro naming the referrer + one bump).

---

## Route 9 — "Nothing in this space right now"

**Trigger examples:** *"We've frozen all hiring"* · *"This isn't a priority for us."*

**Action:** plant-a-flag reply: acknowledge + *"what would need to change for this to become a priority?"* State → `signal_watch`.

**Window:** **no campaign, no timer.** This is the most signal-driven route: the account re-activates only when the outbound engine detects a *fresh* buying signal (a new job posting, a relevant leadership change). Re-contacting on a calendar instead of a signal is how you earn route 4.

---

## Route 10 — Out of office

**Trigger examples:** auto-reply with a return date, in any language.

**Action:** no reply. Parse the return date → pause the lead → `follow_ups` row at return + 2 business days → **resume the same campaign at the same step**.

**Window:** unparseable date → default +14 days. **Never close an OOO** — it's a warm lead on a delay, and the auto-reply just confirmed the address is live and the person exists.

---

## Route 11 — Spam / bounce / invalid

**Trigger examples:** delivery failures, spam responses, auto-generated garbage.

**Action:** stop lead, mark `invalid`, feed list hygiene — a bounce is an *enrichment-source quality signal*: the ledger records which waterfall provider produced the address, so rising bounce rates trace to their source instead of triggering a generic "refresh the list."

**Window:** terminal.

---

## Route 12 — Ambiguous / human review

**Trigger examples:** *"How did you get my email?"* · mixed signals (*"we're not hiring but this is interesting"*) · anything the classifier scores < 0.8 · the 3rd inbound message in any thread (two-turn rule).

**Action:** everything is staged before the human sees it: a Slack card ([rendered mock](../diagrams/hitl-card.html), [Block Kit source](../examples/slack_hitl_card.json)) with the conversation, the classifier's best guess + confidence, a suggested draft, and three buttons — **[Send draft] [Edit] [Close]**. A draft is simultaneously staged in the sequencer's inbox, so the rep can also act from there. The human contribution is one click.

**Window:** unactioned 24 h → one re-ping. **Every click is training data** — approve, edit, or re-route decisions become the labeled corrections that the classifier retrieves as few-shot examples next week ([learning loop](learning-loop.md)).

---

## Waiting windows at a glance

| Route | First action | Bump | Give up / terminal |
|---|---|---|---|
| 1 | 5–20 min | day 3 (2 fresh slots) | booked or 2 bumps |
| 2 | 5–20 min | day 4 | → route 3 |
| 3 | 5–20 min | — | re-engage at date (re-gated) |
| 4 | never | — | terminal + suppress |
| 5 | 5–20 min | — | terminal, 9-mo cooldown |
| 6 | 5–20 min | — | day 5 silence → close, 6-mo |
| 7 | 5–20 min | day 3 if clicked | day 7 no click, 6-mo |
| 8 | referrer: 5–20 min | referred: +1 business day | — |
| 9 | 5–20 min | — | signal-watch (event-driven) |
| 10 | never | — | resume return + 2 days |
| 11 | never | — | terminal |
| 12 | Slack: instant | re-ping 24 h | human decides |
