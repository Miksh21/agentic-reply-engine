-- ============================================================
-- Agentic Reply Engine — ledger schema (reference)
-- Postgres 15+ with pgvector. Illustrative, not a migration.
-- Shared tables with the outbound engine (signals, suppression,
-- senders, follow_ups) shown in abbreviated form at the bottom.
-- ============================================================

create extension if not exists vector;

-- ------------------------------------------------------------
-- messages — every word, both directions, before it's sent
-- ------------------------------------------------------------
create table messages (
  id                bigint generated always as identity primary key,
  conversation_id   bigint not null references conversations(id),
  contact_id        bigint not null,
  account_id        bigint not null,

  direction         text not null check (direction in ('outbound_campaign','outbound_agent','inbound')),
  channel           text not null check (channel in ('email','linkedin','whatsapp')),
  sender_id         bigint references senders(id),          -- null for inbound
  campaign_id       text,                                    -- sequencer id; null for agent replies
  step_id           text,
  variant_id        bigint references variants(id),

  subject           text,
  body_text         text not null,
  body_html         text,

  -- lifecycle: rendered (materialized at enroll) → sent → opened/clicked/bounced
  status            text not null default 'rendered'
                    check (status in ('rendered','queued','sent','opened','clicked','bounced','failed')),
  platform_activity_id text,                                 -- reconciliation key
  platform_message_id  text,

  -- inbound classification (null for outbound)
  route             smallint check (route between 1 and 12),
  classifier_confidence numeric(3,2),
  classifier_entities   jsonb,      -- {proposed_time, referral, return_date, not_before}
  drafted_by        text check (drafted_by in ('template','agent','human')),

  sent_at           timestamptz,
  created_at        timestamptz not null default now(),

  -- plain-english search: lexical + semantic
  fts               tsvector generated always as
                      (to_tsvector('simple', coalesce(subject,'') || ' ' || body_text)) stored,
  embedding         vector(1536)
);

create index messages_conversation_idx on messages (conversation_id, created_at);
create index messages_fts_idx          on messages using gin (fts);
create index messages_embedding_idx    on messages using hnsw (embedding vector_cosine_ops);
create index messages_route_idx        on messages (route) where direction = 'inbound';
create unique index messages_platform_activity_uq
  on messages (platform_activity_id) where platform_activity_id is not null;

-- ------------------------------------------------------------
-- conversations — thread state (feeds the two-turn rule)
-- ------------------------------------------------------------
create table conversations (
  id                bigint generated always as identity primary key,
  contact_id        bigint not null,
  account_id        bigint not null,
  platform_contact_id text not null,        -- inbox API key
  channel_mix       text[] not null default '{}',
  state             text not null default 'active'
                    check (state in ('active','nurture_awaiting','closed_soft','closed_hard',
                                     'signal_watch','meeting_booked','human_review')),
  agent_turns       smallint not null default 0,   -- 3rd inbound ⇒ route 12
  last_route        smallint,
  last_inbound_at   timestamptz,
  last_outbound_at  timestamptz,
  created_at        timestamptz not null default now()
);

-- ------------------------------------------------------------
-- decisions — every agent choice, inputs frozen (audit + learning)
-- ------------------------------------------------------------
create table decisions (
  id                bigint generated always as identity primary key,
  conversation_id   bigint not null references conversations(id),
  message_id        bigint references messages(id),
  decision_type     text not null
                    check (decision_type in ('route','draft','booking','enroll','suppress','escalate')),
  inputs            jsonb not null,   -- score, signals present, thread hash, retrieved few-shots
  output            jsonb not null,   -- route chosen / draft id / event id / campaign id
  model             text,
  prompt_version    text,
  -- human corrections (route 12 clicks) — the classifier's future few-shots
  human_action      text check (human_action in ('approved','edited','rerouted','closed')),
  human_corrected_route smallint,
  created_at        timestamptz not null default now()
);

create index decisions_corrections_idx
  on decisions (decision_type, created_at)
  where human_action is not null;

-- ------------------------------------------------------------
-- outcomes — what reality said back (CRM + booking sync)
-- ------------------------------------------------------------
create table outcomes (
  id                bigint generated always as identity primary key,
  conversation_id   bigint not null references conversations(id),
  outcome           text not null
                    check (outcome in ('meeting_booked','meeting_showed','deal_created',
                                       'deal_won','deal_lost','closed_soft','unsubscribed')),
  value_numeric     numeric,
  source            text not null,    -- crm | booking_tool | ledger
  occurred_at       timestamptz not null,
  created_at        timestamptz not null default now()
);

-- ------------------------------------------------------------
-- variants — copy experiments (bandit state)
-- ------------------------------------------------------------
create table variants (
  id                bigint generated always as identity primary key,
  scope             text not null,    -- 'campaign_step' | 'route_template'
  scope_key         text not null,    -- e.g. 'reengagement:step1' | 'route:6'
  body_template     text not null,
  weight            numeric not null default 1.0,   -- ∝ (positive+1)/(sends+2), recomputed weekly
  sends             int not null default 0,
  replies           int not null default 0,
  positive_replies  int not null default 0,          -- routes 1–2
  status            text not null default 'staged'
                    check (status in ('staged','active','retired')),
  created_at        timestamptz not null default now()
);

-- ------------------------------------------------------------
-- learnings — the weekly loop's output, with autonomy tier
-- ------------------------------------------------------------
create table learnings (
  id                bigint generated always as identity primary key,
  insight_text      text not null,
  evidence          jsonb not null,   -- decision/outcome ids, counts, deltas
  tier              char(1) not null check (tier in ('A','B')),  -- A auto / B staged
  applied_at        timestamptz,      -- null while staged
  approved_by       text,             -- null for tier A
  created_at        timestamptz not null default now()
);

-- ------------------------------------------------------------
-- hybrid search — lexical + semantic, reciprocal-rank fusion
-- ------------------------------------------------------------
create or replace function search_messages(
  q_text       text,
  q_embedding  vector(1536),
  f_direction  text default null,
  f_route      smallint default null,
  f_after      timestamptz default null,
  n            int default 20
) returns table (message_id bigint, score numeric) language sql stable as $$
  with lex as (
    select id, row_number() over (order by ts_rank(fts, websearch_to_tsquery('simple', q_text)) desc) rnk
    from messages
    where fts @@ websearch_to_tsquery('simple', q_text)
      and (f_direction is null or direction = f_direction)
      and (f_route     is null or route     = f_route)
      and (f_after     is null or created_at >= f_after)
    limit 60
  ),
  sem as (
    select id, row_number() over (order by embedding <=> q_embedding) rnk
    from messages
    where embedding is not null
      and (f_direction is null or direction = f_direction)
      and (f_route     is null or route     = f_route)
      and (f_after     is null or created_at >= f_after)
    order by embedding <=> q_embedding
    limit 60
  )
  select coalesce(l.id, s.id),
         coalesce(1.0/(60 + l.rnk), 0) + coalesce(1.0/(60 + s.rnk), 0) as score
  from lex l full outer join sem s using (id)
  order by score desc
  limit n;
$$;

-- ------------------------------------------------------------
-- audit views
-- ------------------------------------------------------------
create view v_conversation_timeline as
  select c.id conversation_id, c.state, m.created_at, m.direction, m.channel,
         m.route, m.drafted_by, left(m.body_text, 200) preview
  from conversations c join messages m on m.conversation_id = c.id
  order by c.id, m.created_at;

create view v_route_performance as
  select m.route, count(*) replies,
         count(*) filter (where o.outcome = 'meeting_booked') meetings,
         round(avg(m.classifier_confidence), 2) avg_confidence
  from messages m
  left join outcomes o on o.conversation_id = m.conversation_id
  where m.direction = 'inbound' and m.route is not null
  group by m.route order by m.route;

create view v_source_quality as               -- list forensics: bounces → source
  select coalesce(m.classifier_entities->>'enrichment_source', 'unknown') source,
         count(*) sends,
         count(*) filter (where m.status = 'bounced') bounces
  from messages m where m.direction != 'inbound'
  group by 1 order by bounces desc;

-- ------------------------------------------------------------
-- shared with the outbound engine (abbreviated)
-- ------------------------------------------------------------
-- senders    (id, name, mailbox_id, platform_user_id, msgraph_user_id,
--             gender,           -- drives grammatical agreement in drafts
--             booking_url, working_hours jsonb)
-- suppression(account_id, contact_id, level, reason, until, created_at)
-- follow_ups (id, conversation_id, due_at, action,   -- resume_lead | enroll_reengagement | bump
--             context jsonb, done_at)
-- signals    (account_id, type, weight, observed_at, ...)  -- see sibling repo
