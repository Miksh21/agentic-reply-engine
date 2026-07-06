"""
Reference implementation of the dispatch layer (WF1's logic, readable form).

Illustrative: the live system runs this as orchestrator workflows, not a
Python service. What this file documents is the ORDER of operations —
guardrails before classification, universal actions before any branch,
suppression re-checked at the send, every decision logged with frozen inputs.
"""

from dataclasses import dataclass
from datetime import date, timedelta

CONFIDENCE_GATE = 0.80
MAX_AGENT_TURNS = 2
HUMAN_ROUTE = 12


@dataclass
class Classification:
    route: int
    confidence: float
    language: str
    entities: dict
    reasoning: str


def handle_inbound(webhook_event, platform, ledger, classifier, crm, slack):
    # -- Guardrail 3: warmup traffic never enters the system ------------
    if platform.is_warmup_traffic(webhook_event):
        return

    # -- Ingest: webhook triggers, inbox API supplies truth -------------
    thread = platform.fetch_conversation(webhook_event.contact_id)
    convo = ledger.upsert_conversation(thread)          # self-healing backfill

    # -- Classify with retrieved corrections as few-shots ---------------
    precedents = ledger.similar_corrections(thread.last_inbound, k=5)
    cls: Classification = classifier.classify(thread, convo, precedents)

    # -- Guardrails 1 + 2: two-turn rule and confidence gate ------------
    if convo.agent_turns >= MAX_AGENT_TURNS:
        cls = cls._replace_route(HUMAN_ROUTE, why="two-turn rule")
    if cls.confidence < CONFIDENCE_GATE:
        cls = cls._replace_route(HUMAN_ROUTE, why="confidence gate")

    # -- Universal actions: before ANY branch ---------------------------
    platform.stop_lead_everywhere(convo.contact_id)     # replied ⇒ no more steps
    ledger.log_message(thread.last_inbound, route=cls.route, cls=cls)
    ledger.log_decision("route", inputs=freeze(convo, thread, precedents),
                        output=cls, prompt_version=classifier.version)
    crm.write_activity(convo, cls)
    ledger.touch_cooldown(convo.account_id)

    DISPATCH[cls.route](convo, cls, platform, ledger, crm, slack)


# ----------------------------------------------------------------------
# Route branches (each sends via the single sender sub-workflow — ADR-6)
# ----------------------------------------------------------------------

def send(ledger, platform, convo, draft, channel=None):
    """The one mouth. Guardrails 4 + 5 live HERE, not in the branches."""
    if ledger.is_suppressed(convo.account_id, convo.contact_id):   # guardrail 5
        ledger.log_decision("suppress", inputs={"at": "send"}, output={})
        return
    msg = ledger.write_ahead(convo, draft)              # row exists before send
    platform.send_in_thread(convo, draft,
                            channel or convo.last_inbound_channel,  # channel-match
                            delay=humanizer_delay())    # guardrail 4
    ledger.mark_sent(msg)
    convo.agent_turns += 1


def route_1_book_it_now(convo, cls, platform, ledger, crm, slack):
    rep = convo.thread_sender                           # never round-robin
    t = cls.entities.get("proposed_time")
    if t and calendar_free(rep, t):
        recheck = calendar_free(rep, t)                 # race guard
        event = create_invite(rep, convo, t) if recheck else None
        draft = confirm_draft(convo, t) if event else counter_offer(rep, convo)
    else:
        draft = counter_offer(rep, convo)               # 2-3 slots + booking link
    send(ledger, platform, convo, draft)
    crm.create_deal(convo, stage="meeting_proposed")
    slack.fyi(rep, convo)                               # informational, not approval
    ledger.schedule_bump(convo, days=3, kind="fresh_slots")


def route_2_nurture(convo, cls, platform, ledger, crm, slack):
    send(ledger, platform, convo, one_qualifying_question(convo, cls))
    convo.state = "nurture_awaiting"
    ledger.schedule_bump(convo, business_days=4)


def route_3_timing(convo, cls, platform, ledger, crm, slack):
    when = cls.entities.get("not_before") or date.today() + timedelta(days=90)
    send(ledger, platform, convo, timing_confirm(convo, when))
    ledger.schedule_followup(convo, due=when, action="enroll_reengagement")
    # WF3 re-checks suppression AND fresh signals at fire time — not here.


def route_4_hard_no(convo, cls, platform, ledger, crm, slack):
    platform.unsubscribe(convo.contact_id)              # no reply. ever.
    ledger.suppress(contact=convo.contact_id, level="permanent")
    ledger.suppress(account=convo.account_id, months=12)
    crm.mark_not_interested(convo)


def route_5_soft_no(convo, cls, platform, ledger, crm, slack):
    send(ledger, platform, convo, warm_close_with_seed(convo))
    convo.state = "closed_soft"
    ledger.suppress(contact=convo.contact_id, months=9)
    # rate per campaign feeds the weekly report: spikes = targeting problem


def route_6_incumbent(convo, cls, platform, ledger, crm, slack):
    send(ledger, platform, convo,
         incumbent_probe(convo, cls.entities.get("incumbent")))
    ledger.schedule_close(convo, business_days=5, cooldown_months=6)


def route_7_more_info(convo, cls, platform, ledger, crm, slack):
    asset = ledger.asset_for(convo.segment)
    if asset is None:                                   # no asset ⇒ no route
        return route_12_human(convo, cls, platform, ledger, crm, slack)
    send(ledger, platform, convo, info_paragraph(convo, asset))  # 1 para + 1 link + 1 question
    ledger.schedule_click_watch(convo, bump_day=3, close_day=7)


def route_8_referral(convo, cls, platform, ledger, crm, slack):
    ref = cls.entities["referral"]
    send(ledger, platform, convo, thank_referrer(convo, ref))
    person = resolve_referred(ref, convo.account_id)    # waterfall or role-holder
    if person and not ledger.is_suppressed(convo.account_id, person.id):
        platform.enroll(person, campaign="referral",
                        variables={"referrer_name": convo.contact_name,
                                   "context_snippet": ledger.snippet(convo)},
                        delay_business_days=1)          # referrer's heads-up lands first
    convo.state = "closed_won_referral"


def route_9_not_in_space(convo, cls, platform, ledger, crm, slack):
    send(ledger, platform, convo, plant_a_flag(convo))
    convo.state = "signal_watch"                        # no timer — a fresh signal reactivates


def route_10_ooo(convo, cls, platform, ledger, crm, slack):
    back = cls.entities.get("return_date") or date.today() + timedelta(days=14)
    platform.pause_lead(convo.contact_id)               # no reply to an auto-reply
    ledger.schedule_followup(convo, due=back + timedelta(days=2),
                             action="resume_lead")      # same campaign, same step


def route_11_invalid(convo, cls, platform, ledger, crm, slack):
    platform.stop_lead_everywhere(convo.contact_id)
    ledger.mark_invalid(convo.contact_id)               # bounce → source forensics


def route_12_human(convo, cls, platform, ledger, crm, slack):
    draft = suggest_draft(convo, cls)                   # staged, never sent
    platform.create_inbox_draft(convo.contact_id, draft)
    slack.hitl_card(convo, cls, draft)                  # [Send] [Edit] [Close]
    convo.state = "human_review"
    ledger.schedule_reping(convo, hours=24)
    # WF4 handles the click; every click lands in decisions.human_action
    # and becomes next week's few-shot correction.


DISPATCH = {1: route_1_book_it_now, 2: route_2_nurture, 3: route_3_timing,
            4: route_4_hard_no, 5: route_5_soft_no, 6: route_6_incumbent,
            7: route_7_more_info, 8: route_8_referral, 9: route_9_not_in_space,
            10: route_10_ooo, 11: route_11_invalid, 12: route_12_human}
