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
| Tokens on tool usage in March | **Answered** — `claude.llm_requests`, below | — |
| Where tokens go past 400k context | Yes | — |
| Avg turns to complete a ticket | **Not yet** | which ticket, and whether it completed |
| Opus 5 vs 4.8 review convergence | **Not yet** | what marks a session as a review |

That gap sets the priority for everything else. Storage can be migrated; an attribute
that was never emitted is gone. **What gets recorded is perishable. Where it's stored is
not.** Every day without work-unit labels is another day that can never answer questions
3 and 4, retroactively, forever — which is why the labelling ticket outranks the more
interesting ClickHouse ticket.

The fix was cheap, and as of 2026-08-23 it is in: `./ct claude` stamps
`vcs.repository.name`, `vcs.ref.head.name`, and `process.working_directory` onto every
span of the session through `OTEL_RESOURCE_ATTRIBUTES`, and they are searchable as Jaeger
process tags. That closes the "which repo, which branch" half of the gap for every
session launched that way. Both remaining columns above need one more join each — the
ticket and its completion (ticket 6), and whatever marks a session as a review, which
nothing derives automatically and which rides in on the launcher's passthrough.

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

**But the two attributes you need are on different spans.** Measured 2026-08-23 by running
a traced session that spawns a subagent, because no session traced up to that point had
spawned one and the whole subagent story was going on unverified. `subagent_type` is
stamped on the `tool` span for the `Agent` call; `agent_id` is stamped on the
`llm_request` spans the subagent itself makes, which hang two levels below it:

```
claude_code.tool  tool_name=Agent  subagent_type=general-purpose
└─ claude_code.tool.execution
   └─ claude_code.llm_request  agent_id=a09810…  llm_request.context=tool
```

They never appear on the same row, so attributing tokens to a *kind* of subagent is a
two-hop join up the span tree, not a `GROUP BY` — and a join that gets one hop wrong
returns a number that looks entirely reasonable. It's written once as the
`claude.subagent_requests` view rather than left for each query to rediscover.

`llm_request.context` was the useful surprise: it reads `tool` on a subagent's requests
and `interaction` on the main agent's, which separates the two populations with no join
at all. `parent_agent_id` is still unobserved — it presumably needs agents nested inside
agents. The column exists and is empty.

## The architecture that follows

As of 2026-08-23 this is built, not proposed: `./ct up` starts ClickHouse alongside
Jaeger, `./ct sql` queries it, and `./ct verify` fails if a span reaches one sink and not
the other.

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
installed globally. Two things about that binary were not obvious until measured: the
only versioned macOS build is a GitHub release asset (`clickhouse-macos-aarch64`), since
`builds.clickhouse.com` publishes macOS from master only, and it is self-extracting — it
rewrites itself from 161 MB to 855 MB the first time it runs, so its installed hash never
matches what was downloaded.

### One question that's harder than it looks, and how it was settled

"Tokens spent on tool usage" has no structural answer. Tokens live on `llm_request` spans,
tools live on `tool` spans, and they are **siblings** under an interaction — not parent and
child. Nothing links a token count to a tool call. What does link them is the *order* of
requests, so the answer is a window over the request sequence rather than a join.

Settled 2026-08-23 as the `claude.llm_requests` view. A request serves a tool call when it
**decided** to make one (`stop_reason='tool_use'`), **carried** one's result (it follows a
`tool_use` request under the same parent span), or **ran inside** one
(`llm_request.context='tool'`, a subagent). It's a union over requests, not a sum over tool
calls: a request meeting all three clauses is counted once, so the figure can't exceed the
month's total. Every later question inherits this.

Two numbers come out of it, and both are worth reporting because they disagree by two
orders of magnitude:

| Measure | What it counts | Observed |
| --- | --- | --- |
| `sumIf(TotalTokens, ServesToolCall)` | every billed token on a request that serves a tool call | **97.8%** of all tokens |
| `sum(ToolResultTokens)` | context growth beyond what the model itself wrote — the tool output itself | **0.8%** of all tokens |

Tools *cause* almost all the spend; tool output *is* almost none of it. The gap is context
being re-read on every turn of the loop, which the raw counts make plain: 18.4M cache-read
tokens against 246 fresh input tokens.

Three findings from building it, none of which were predictable from the span schema:

- **Requests partition by session *and* parent span, and a missing parent falls back to the
  row's own span id.** Main-agent requests hang off their `interaction` span, a subagent's
  off the `tool.execution` that spawned it, and `standalone` requests (title generation) off
  nothing at all. Both halves of that key were paid for: partitioning by session alone pairs
  a subagent's request with the main agent's previous one, measured at −7,393 on a real
  session; and partitioning on an empty `ParentSpanId` directly files every parentless
  request in a session under one window, which chains two unrelated standalone requests and
  attributes −29,600 tokens to a tool call that never happened. An absent parent is not a
  parent they share, so it cannot be a group.
- **The context arithmetic is exact.** `ContextTokens(n+1) − ContextTokens(n) −
  OutputTokens(n)` was positive on all 124 consecutive pairs where the predecessor ended in
  `tool_use` (min 12, median 233, max 19,903). It is left signed rather than clamped, so a
  negative one — a context rewritten mid-interaction — surfaces instead of vanishing.
- **A `LowCardinality(String)` comparison yields `LowCardinality(UInt8)`,** which ClickHouse
  refuses to store as a column. Any boolean derived from `StopReason` needs an explicit
  `CAST(… AS Bool)`.

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
| Claude Code honors `OTEL_RESOURCE_ATTRIBUTES` | **Measured** — 2.1.226; attributes land as Jaeger process tags and answer a tag search |
| One raw space discards the whole attribute set | **Measured** — controlled pair, one variable changed; see below |
| Events pipeline volume vs its 256 MB ceiling | **Unmeasured** — nobody has counted; ticket 7 measures first |
| `agent_id` on llm_request, `subagent_type` on the Agent tool span | **Measured** — traced session spawning a subagent, 2026-08-23 |
| `parent_agent_id` exists at all | **Unmeasured** — never seen in this stack's data; the column is empty |
| ClickHouse self-extracts on first run | **Measured** — 161 MB downloaded, 855 MB after one `--version` |
| Context delta after a `tool_use` request is always positive | **Measured** — all 124 consecutive pairs in the store, none negative |
| Tool usage is 97.8% of tokens, tool output 0.8% | **Measured** — but on 145 requests from one day, not a month; re-run before quoting |
| Subagent requests parent to `tool.execution`, not to `interaction` | **Measured** — hand-checked against session `c11da405` |

The encoding result is worth stating on its own, because its failure mode is invisible.
Two runs of the same prompt, one variable changed:

| `OTEL_RESOURCE_ATTRIBUTES` | What reached Jaeger |
| --- | --- |
| `ct.nonce=X,ct.enc=a%20b%2Cc` | both attributes, decoded to `a b,c` |
| `ct.nonce=X,ct.enc=a b` | nothing — including the well-formed `ct.nonce` |

There is no partial parse and no complaint. Since git permits commas in branch names and
paths routinely contain spaces, percent-encoding the values isn't tidiness — it's what
stands between one stray character and a session labelled with nothing at all.

A third defect surfaced while landing ClickHouse and was fixed there rather than
ticketed. `ct_install_tool` decided a binary was already installed by re-hashing it and
comparing to the pin — fine for two immutable binaries, wrong for a self-extracting one.
ClickHouse failed that check forever and re-downloaded 161 MB on every single `./ct up`,
quietly, because a re-download looks exactly like a first install. The pin is checked once
now, against the bytes off the network, and the result is kept in a `.verified` file
rather than re-derived from a file the program owns.

Two live defects found along the way, both recorded as tickets:

- The metrics endpoint on `:8889` answers `HTTP 200` with `Content-Length: 0`. The data
  arrives — `otelcol_exporter_sent_metric_points{exporter="prometheus"} 7` — and then
  evaporates, because a scrape surface drops series nothing pulls. An empty 200 is the
  worst possible answer: shaped exactly like success, meaning *I lost your data*.
- `ct verify` proved only that traces reach Jaeger, so the above rotted undetected for
  hours while verify passed. Any new sink needs to be inside verify's definition of done,
  or it will rot the same way. Work-unit labels were brought inside it when they landed —
  verify now tag-searches Jaeger for the labels the probe session was launched with. The
  metrics endpoint still isn't covered; that's ticket 3.

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

On-disk size, which is the one number above that is still assumed rather than measured.
Once there is a real month in ClickHouse, this settles the 150–400 MB/year estimate:

```bash
./ct sql "SELECT partition,
                 sum(rows) AS rows,
                 formatReadableSize(sum(data_compressed_bytes))   AS on_disk,
                 formatReadableSize(sum(data_uncompressed_bytes)) AS raw,
                 round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
          FROM system.parts
          WHERE database = 'claude' AND table = 'spans' AND active
          GROUP BY partition ORDER BY partition FORMAT PrettyCompact"
```

## Where this is tracked

Epic `claude-analytics-zbi` in this repo's lit backlog, seven children in rank order.
`lit backlog` for the queue, `lit show claude-analytics-zbi` for the plan.

The epic is not the whole backlog. Five repo-hygiene items sit below it — the `ct down`
pidfile ordering bug, the `ct logs` glob on a fresh checkout, darwin/arm64-only tool pins,
autostart, and the all-or-nothing env profile. They rank lower because unrecorded data is
perishable and a shell glob is not, which is a statement about ordering, not about whether
they matter.
