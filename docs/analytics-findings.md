# Can this stack answer analytical questions about a year of Claude Code usage?

Yes, but not with what it records today. This is what came out of measuring the running
stack and 30 days of real transcripts on 2026-08-23, and the architecture that follows
from it. Every number below says where it came from; the last section is the commands to
re-derive them, because usage changes and a stale number here is worse than no number.

The four questions this was measured against, verbatim:

- the number of tokens I spent on tool usage in march
- does my code review process converge more quickly with Opus 5 or Opus 4.8
- what's the average number of turns needed to complete a ticket with Sonnet 5
- when a session exceeds 400k tokens in context, where am I spending those tokens

## The finding that reframes the rest

**Half of those questions cannot be answered by any database, because the data isn't
being recorded.**

Claude Code's spans carry model, tokens, tool names, timings, turn number, session id,
agent id, and your identity. They carry nothing about the *work*: no working directory,
no git branch, no ticket, no notion of what the session was for.

| Question | Answerable from today's spans? | Missing |
| --- | --- | --- |
| Tokens on tool usage in March | Yes | — |
| Where tokens go past 400k context | Yes | — |
| Avg turns to complete a ticket | **No** | which ticket, and whether it completed |
| Opus 5 vs 4.8 review convergence | **No** | what marks a session as a review |

That gap sets the priority for everything else. Storage can be migrated; an attribute
that was never emitted is gone. **What gets recorded is perishable. Where it's stored is
not.** Every day without work-unit labels is another day that can never answer questions
3 and 4, retroactively, forever — which is why the labelling ticket outranks the more
interesting ClickHouse ticket.

The likely fix is cheap. OTel's `OTEL_RESOURCE_ATTRIBUTES` stamps arbitrary key-values
onto every span a process emits, so a launcher setting repo, branch, and current ticket
would put the join key on all ~50 spans of a session at no marginal cost. **This is
assumed, not verified** — see the confidence table below.

## Volume, measured

Thirty days of transcripts under `~/.claude/projects` (634 MB, 786 files, 109 projects):

```
real user turns      4,061
assistant messages  80,568        ~20 per user turn
tool_use calls      41,341
active days             23        median 79 turns/day, peak 529
```

Claude Code emits one span per interaction, one per LLM request, and three per tool call
(`tool`, `blocked_on_user`, `execution`). Span sizes measured from live Jaeger (n=74,
small sample — treat as ±30%):

| span type | count / 30d | measured size | bytes / 30d |
| --- | ---: | ---: | ---: |
| `llm_request` | 80,568 | 2,845 B | 229 MB |
| `tool` | 41,341 | ~2,300 B | 95 MB |
| `tool.execution` | 41,341 | 1,556 B | 64 MB |
| `tool.blocked_on_user` | 41,341 | 1,448 B | 60 MB |
| `interaction` | 4,061 | 1,450 B + prompt | ~26 MB |
| **total** | **209,000** | | **~474 MB / month** |

**~5.7 GB/year raw.** Two things about the composition are worth knowing before designing
a schema.

**`llm_request` is half the volume** — 80,568 of them, each ~2.8 KB of pure metadata with
no prompt text. Your actual prompts are a rounding error (26 MB) even with a p99 length of
57 KB and one outlier at 690 KB.

**Roughly 60% of every span is the same identity block repeated verbatim.** Look at
`blocked_on_user`: 1,448 bytes for a span whose entire payload is a duration and a
decision. The rest is `user.email`, `user.id` (64 hex chars), `user.account_uuid`,
`organization.id`, `session.id`, `terminal.type`, and scope name/version — stamped onto
all 209,000 spans a month. That's ~290 MB/month of the same handful of strings.

Row stores pay full freight for that. A columnar store dictionary-encodes it to one
distinct value plus an index, which is the strongest argument for ClickHouse on *this
specific data* — not general OLAP theory, but the shape of Claude Code's attribute set.

## What a span actually contains

Every distinct attribute key across live traces, so nobody has to re-query to find out:

```
tokens     input_tokens  output_tokens  cache_creation_tokens  cache_read_tokens
model      model  gen_ai.request.model  gen_ai.system  speed
timing     duration_ms  ttft_ms  interaction.duration_ms
structure  session.id  interaction.sequence  span.type  llm_request.context  attempt
tools      tool_name  full_command  tool_use_id  gen_ai.tool.call.id  decision  source
outcome    stop_reason  success  gen_ai.response.finish_reasons
identity   user.email  user.id  user.account_uuid  user.account_id  organization.id
content    user_prompt  user_prompt_length  terminal.type
```

Notable absences: **no cost field of any kind**, and **no context-size field**. Cost
exists only in the separate metrics signal. Context size has to be derived —
`input_tokens + cache_read_tokens + cache_creation_tokens` on an `llm_request` is the
workable proxy, and it's what the 400k question needs.

**Subagents dominate.** 80,568 assistant messages against 4,061 user turns is a 20:1
ratio: almost everything Claude does on your behalf happens inside a subagent. So "where
are my tokens going" resolves to *which subagent*, not which prompt. `agent_id`,
`parent_agent_id`, and `subagent_type` are primary grouping keys, not incidental tags —
a table that buries them in a generic attribute map makes every expensive query an
extraction later.

## The architecture that follows

Jaeger already does one job well: view a single trace, seven days, badger, ~110 MB
steady state. Nothing about that needs to change. A year of history answering
`sum(tokens) group by month` is a different job with a different access pattern.

```
claude ──▶ collector ─┬─▶ jaeger + badger    7 days   viewing (works today)
                      └─▶ clickhouse         1 year+  SQL analytics
```

The collector already fans signals out — traces to Jaeger, metrics to Prometheus, logs to
a file — so this adds an exporter rather than rewiring anything.

**Jaeger deliberately does not sit on ClickHouse.** Jaeger 2.20 ships a ClickHouse backend,
but the binary prints `WARNING: ClickHouse Storage is Experimental`, and there's no reason
to put a working viewer behind it. Two sinks, two jobs, no dependency between them: if the
ClickHouse path breaks, viewing still works.

The duplication is intentional and has an owner. The collector's stream is the source of
truth; ClickHouse is the system of record for history, badger is a 7-day cache for the UI.
Neither is authoritative over the other.

ClickHouse ships as a single static binary, so it fits how this repo already works —
pinned under `var/bin`, a row in `ct_tool_pins()` and `ct_services()`, no Docker, nothing
installed globally.

### One question that's harder than it looks

"Tokens spent on tool usage" has no structural answer. Tokens live on `llm_request` spans,
tools live on `tool` spans, and they are **siblings** under an interaction — not parent and
child. Nothing links a token count to a tool call.

Two defensible readings, and they give different numbers:

- tokens of requests that ended in `stop_reason=tool_use` — what it cost to *decide* to
  call a tool
- plus tokens of the *following* request, which carries the tool result back into context

The second is where the money is: a tool returning 40 KB of output is paid for on the next
request, not its own. Pick deliberately and write the definition next to the query — every
later question inherits it.

## Confidence: measured, derived, assumed

The first volume estimate in this investigation was wrong by 5× because a usage rate was
invented rather than counted. This table exists so that can't happen quietly again.

| Claim | Basis |
| --- | --- |
| 4,061 turns / 80,568 assistant msgs / 41,341 tools in 30d | **Measured** — counted from transcript JSONL |
| Span sizes per type | **Measured** — live Jaeger API, n=74, small sample |
| 209,000 spans/month, ~474 MB/month, ~5.7 GB/year | **Derived** — measured counts × measured sizes |
| Attribute inventory, absence of cost field | **Measured** — every key across live traces |
| ClickHouse compression 20–50× → 150–400 MB/year | **Assumed** — reasoned from the 60% redundancy, not benchmarked |
| Claude Code honors `OTEL_RESOURCE_ATTRIBUTES` | **Assumed** — standard OTel SDK behavior, untested here |
| Events pipeline volume vs its 256 MB ceiling | **Unmeasured** — nobody has counted; ticket 7 measures first |

Two live defects found along the way, both recorded as tickets:

- The metrics endpoint on `:8889` answers `HTTP 200` with `Content-Length: 0`. The data
  arrives — `otelcol_exporter_sent_metric_points{exporter="prometheus"} 7` — and then
  evaporates, because a scrape surface drops series nothing pulls. An empty 200 is the
  worst possible answer: shaped exactly like success, meaning *I lost your data*.
- `ct verify` proves only that traces reach Jaeger, so the above rotted undetected for
  hours while verify passed. Any new sink needs to be inside verify's definition of done,
  or it will rot the same way.

## Re-measuring

Usage changes. Re-run these rather than trusting the numbers above.

Turns, assistant messages, and tool calls over the last 30 days:

```bash
find ~/.claude/projects -name '*.jsonl' -type f -mtime -30 -print0 \
 | xargs -0 cat \
 | python3 -c "
import sys, json, collections
tools=0; user_turns=0; asst=0; days=collections.Counter()
for line in sys.stdin:
    try: o=json.loads(line)
    except Exception: continue
    t=o.get('type'); ts=(o.get('timestamp') or '')[:10]
    if t=='user':
        c=(o.get('message') or {}).get('content')
        if isinstance(c,str) or (isinstance(c,list) and not any(
                b.get('type')=='tool_result' for b in c if isinstance(b,dict))):
            user_turns+=1; days[ts]+=1
    if t=='assistant':
        asst+=1
        for b in ((o.get('message') or {}).get('content') or []):
            if isinstance(b,dict) and b.get('type')=='tool_use': tools+=1
print(f'turns {user_turns:,}  assistant {asst:,}  tools {tools:,}  days {len(days)}')
"
```

Span sizes by type, from live Jaeger:

```bash
curl -s "http://127.0.0.1:16686/api/traces?service=claude-code&lookback=12h&limit=200" \
 | python3 -c "
import json,sys,collections,statistics
by=collections.defaultdict(list)
for t in (json.load(sys.stdin).get('data') or []):
    for s in t['spans']: by[s['operationName']].append(len(json.dumps(s)))
for k,v in sorted(by.items()):
    print(f'{k:35s} n={len(v):3d} median {statistics.median(v):6.0f}B')
"
```

Span totals follow from the counts: `interactions + assistant_msgs + 3 × tool_calls`.

## Where this is tracked

Epic `claude-analytics-zbi` in this repo's lit backlog, seven children in rank order.
`lit backlog` for the queue, `lit show claude-analytics-zbi` for the plan.

The epic is not the whole backlog. Five repo-hygiene items sit below it — the `ct down`
pidfile ordering bug, the `ct logs` glob on a fresh checkout, darwin/arm64-only tool pins,
autostart, and the all-or-nothing env profile. They rank lower because unrecorded data is
perishable and a shell glob is not, which is a statement about ordering, not about whether
they matter.
