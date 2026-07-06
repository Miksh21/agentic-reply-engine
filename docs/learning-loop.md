# The Learning Loop

The sibling repo listed "a planned reweighting loop" in its roadmap. This is that loop, built. The trick is not machine learning — it's **bookkeeping**: log every decision with its inputs frozen, log every outcome, and join them weekly.

## The two tables that make it possible

- **`decisions`** — every agent choice (route classification, draft sent, invite created, enrollment, suppression) with a snapshot of what the agent knew: score, signals present, thread context, prompt version, model.
- **`outcomes`** — what reality said back, synced from the CRM and booking tool: meeting booked, meeting showed, deal created, deal won, closed soft, unsubscribed.

Everything below is a join between these two.

## WF7 — weekly, three learning surfaces

### 1. Classifier self-improvement (highest ROI, zero risk)

Every route-12 human click is a **labeled example**: the human approved the suggested route (confirmation), edited the draft (style correction), or re-routed entirely (classification correction). These land in a corrections pool.

At classification time, the router retrieves the 5 most similar past corrections (vector search over reply embeddings) and injects them as few-shot examples. The classifier improves weekly **without fine-tuning and without deployment** — and `prompt_version` on every decision row means the improvement is measurable, not vibes: route-12 escalation rate and human re-route rate should both fall over time. If they don't, the corrections pool is telling you the taxonomy itself is wrong, which is also worth knowing.

### 2. Copy evolution (bandit on variants)

Per campaign step and per route template: sends, replies, *positive* replies (routes 1–2 count; route 4 counts against). Sampling weight per variant follows a Thompson-style rule — weight ∝ (positive + 1) / (sends + 2) — so winners get traffic gradually, not in winner-take-all lurches that destroy your statistics.

The agent drafts **one new challenger variant** per underperforming step per week — staged, not auto-applied (see tiers below).

### 3. Signal reweighting (feeds the outbound engine)

Join signals-present-at-decision-time against outcomes: which signal types actually preceded meetings? Which "hot" combinations produced route-4 and route-5 replies (over-scored) — and which "cool" accounts booked meetings anyway (under-scored)? Adjust weight and decay half-life in the outbound engine's scoring model.

This closes the full circle: **outbound engine → replies → this engine → outcomes → back into outbound scoring.** The two repos are one machine.

## Tiered autonomy — the honest limit of "fully agentic"

A self-modifying system needs a floor. The tier split:

| Tier | Changes | Applied by |
|---|---|---|
| **A — auto** | variant sampling weights, send windows, follow-up timings, classifier few-shot pool | WF7, silently, logged in `learnings` |
| **B — staged** | new copy variants, targeting/ICP changes, signal weight changes > 20% | Monday Slack digest, one-click apply |

The rationale: Tier A changes are numeric, bounded, and reversible — automation is safe. Tier B changes **compound**: a copy loop that rewrites its own voice with no floor can drift the entire outbound tone in a month with nobody noticing, and by then every variant descends from the drifted ancestor. One weekly digest costs the human ~3 minutes and uses the same one-click pattern as route 12.

This is the same design instinct as the route-12 escalation: full autonomy where there's a playbook and bounded blast radius; a cheap human gate exactly where errors compound.

## Cold-start honesty

The loop is meaningless until decisions and outcomes accumulate — realistically **4–6 weeks** of live traffic. Build order reflects that: the ledger ships first (useful from day one for search and audit), the learning job ships last. Turning on a bandit with 30 sends per variant just launders noise into confident-looking weights.
