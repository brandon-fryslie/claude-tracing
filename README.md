# claude-tracing

Runs a local OpenTelemetry Collector and Jaeger, and points Claude Code at them, so
you can open a session in a trace viewer and see where the time and tokens went.

Both are native binaries. There is no Docker, no VM, and nothing to install globally —
`./ct up` downloads two pinned executables into `var/bin` and starts them.

## Quickstart

```bash
./ct up                  # fetch binaries, start the stack, wait until it answers
./ct claude              # work normally, traced and labelled
open http://127.0.0.1:16686
```

`./ct claude` runs Claude in whatever directory you are standing in, so from another
project you call it by path — `~/code/claude-tracing/ct claude` — or alias it. It prints
the labels it stamped before handing over, and passes every argument through, so
`./ct claude -p 'hi'` and `./ct claude --resume` work as usual.

To prove the whole path works before you trust it:

```bash
./ct verify
```

Three stages, cheapest first. It checks the label encoding without touching the network,
sends a synthetic span through the collector and waits for it in Jaeger, then runs a real
one-prompt session through the launcher and waits for *its* span — and for a Jaeger tag
search on the labels that session was launched with. Every stage that talks to Jaeger
plants a random nonce and searches for that exact string, so a pass means this run's data
arrived, not that some older trace is still lying around.

## What you get

![A Claude Code turn in Jaeger](docs/jaeger-trace.png)

One trace per prompt. A turn that ran a single Bash command looks like this:

```
claude_code.interaction              3523.9ms   user_prompt="Run the bash command …"
├─ claude_code.llm_request           2136.0ms   model=claude-opus-5[1m] ttft_ms=1093
│                                               input_tokens=2 output_tokens=85
│                                               cache_read_tokens=0 stop_reason=tool_use
├─ claude_code.tool                   605.0ms   tool_name=Bash
│                                               full_command="echo claude-tracing-selftest"
│  ├─ claude_code.tool.blocked_on_user   4.5ms  ← how long you took to approve it
│  └─ claude_code.tool.execution       600.3ms
└─ claude_code.llm_request            752.0ms   cache_read_tokens=26923 stop_reason=end_turn
```

Every span carries `session.id`, so a Jaeger tag search on one id pulls up every turn
of a session. Subagents land in the same trace as the `Agent` call that spawned them:
the tool span is tagged `subagent_type=general-purpose`, and the requests the subagent
makes are tagged with its `agent_id` (plus `parent_agent_id`, once agents nest).

The `blocked_on_user` span is the one worth knowing about: it separates the time Claude
spent working from the time it spent waiting on you to hit approve.

Jaeger 2.20 also has a **GenAI View** toggle in the trace header, next to the search
box, which reads the `gen_ai.*` attributes Claude Code sets.

## Knowing what a session was for

Claude Code's own attributes describe the session — model, tokens, timings, identity —
and say nothing about the work. So "how many turns did that ticket take" has nothing to
group by, and no storage engine fixes that later: an attribute that was never emitted
can't be backfilled. `./ct claude` fills the gap, stamping onto every span of the session:

| Attribute | Value |
| ------------------------------ | ------------------------------------------------ |
| `vcs.repository.name`          | the git repository's directory name              |
| `vcs.ref.head.name`            | the current branch; absent on a detached HEAD    |
| `process.working_directory`    | where you launched from                          |

Those are OpenTelemetry semantic conventions rather than names invented here, and they
arrive as Jaeger *process* tags — so one tag search pulls every span of every session
that ran in a given repo or on a given branch. Launch somewhere that isn't a git
checkout and the two `vcs.*` labels are simply absent, which reads as "doesn't apply"
rather than as a branch whose name is the empty string.

Whatever you set in `OTEL_RESOURCE_ATTRIBUTES` yourself is kept and merged, so you can
label the things this repo can't derive — like what the session is *for*:

```bash
OTEL_RESOURCE_ATTRIBUTES=session.purpose=code-review ./ct claude
```

One warning, measured rather than assumed: a single raw space anywhere in
`OTEL_RESOURCE_ATTRIBUTES` makes Claude Code discard *every* attribute in the string,
silently, including the well-formed ones beside it. `ct claude` percent-encodes what it
derives and refuses to launch if what you passed in would poison the set. If you set that
variable by hand for a plain `claude`, encode the spaces as `%20` yourself.

The labels describe the directory you launched from, which is why they are computed at
launch and are not part of `./ct env`. A shell that sourced the env in one repo would go
on claiming that repo long after you'd moved to another.

## How it's wired

Claude Code emits three OTLP signals, and Jaeger accepts exactly one of them. Point
Claude straight at Jaeger and its metrics and logs pipelines get `Unimplemented` back —
two thirds of the telemetry disappears without anyone telling you. The collector exists
to give each signal a real sink:

```
claude  ──OTLP/gRPC──▶  collector :4317  ──traces──▶  jaeger :14317 ──▶ badger on disk
                                         ──metrics─▶  :8889/metrics (Prometheus format)
                                         ──logs────▶  var/log/claude-events.jsonl
```

| Port    | What                                                        |
| ------- | ----------------------------------------------------------- |
| `4317`  | Collector OTLP gRPC — the only address Claude is ever given |
| `4318`  | Collector OTLP HTTP                                         |
| `16686` | Jaeger UI and query API                                     |
| `8889`  | Claude's metrics: cost in USD, tokens by type, session count |
| `14317` | Jaeger's OTLP receiver, moved aside so the collector owns 4317 |

Ports, versions, and binary checksums are all defined once, in `lib/common.sh`. The two
YAML configs read them back through OpenTelemetry's `${env:...}` expansion rather than
restating them, so there is no second copy to drift.

Jaeger v2 is itself a Collector distribution, which is why `config/jaeger.yaml` and
`config/collector.yaml` look alike: same schema, same `--config` flag. `ct` treats both
services as the same kind of thing — a binary that takes a config and answers a
readiness URL — and starts them by iterating a table rather than by branching.

## What gets recorded

None of this leaves the machine, but it is more than timings. The default env printed by
`./ct env` records:

- **Your prompt text**, verbatim, as `user_prompt` on the root span (`OTEL_LOG_USER_PROMPTS=1`).
- **Bash commands, file paths, skill names, and subagent types** on tool spans (`OTEL_LOG_TOOL_DETAILS=1`).
- **Your email, account UUID, and organization id** as labels on every metric. That is
  Claude Code's own default label set, not something this repo adds.
- **The repository, branch, and absolute working directory** you launched in, on every
  span of a session started with `./ct claude`. This one *is* something this repo adds.

Tool inputs and outputs are *not* captured. Add `export OTEL_LOG_TOOL_CONTENT=1` after
sourcing if you want them — every file you read and every command's output becomes a
span event, truncated at 60 KB each. It makes traces large.

## Operating it

```bash
./ct status    # is each service running, and is it answering
./ct logs      # tail both service logs
./ct ui        # open Jaeger
./ct down      # stop
```

Traces live in badger under `var/jaeger` and expire after 7 days (`CT_TRACE_TTL` in
`lib/common.sh`). They survive restarts. To start clean, `./ct down && rm -rf var/jaeger`.

Everything under `var/` is disposable and gitignored — binaries, pidfiles, logs, and
storage all come back from `./ct up`.

If you'd rather trace every session without going through the launcher, paste the output
of `./ct env` into the `env` block of `~/.claude/settings.json`. Claude Code will then try
to export whether or not the stack is up. That route carries the transport but not the
work-unit labels, which have to be computed per launch — those sessions land in Jaeger
with no repo and no branch on them.

## Troubleshooting

**No `claude-code` service in the Jaeger dropdown.** Spans are a beta feature gated on
`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`, which `./ct env` sets. If they still don't
arrive, your build or account may not have it — verified working on Claude Code 2.1.226.
Run `./ct verify`: if stage 1 passes and stage 2 fails, the stack is fine and the
problem is on Claude's side.

**Spans arrive with no repo or branch on them.** They were emitted by a `claude` that
didn't go through `./ct claude` — a shell that sourced `./ct env`, or the settings.json
route. Both carry the transport and neither carries the labels.

**A service won't start.** `./ct up` prints the last 20 lines of that service's log
before giving up. The full logs are in `var/log/`.

**Spans are slow to appear.** Claude batches exports every 5 seconds and the collector
batches for 2 more, so allow about 10 seconds after a turn ends.

**Port conflict.** Change the port in `lib/common.sh` and restart; both configs pick up
the new value.

## Adding another platform

`ct_tool_pins()` in `lib/tools.sh` pins the sha256 of each binary for darwin/arm64 only.
On any other platform `./ct up` stops and tells you what to add rather than installing
something unverified: download the release tarball, run `shasum -a 256` on the extracted
binary, and add a row.
