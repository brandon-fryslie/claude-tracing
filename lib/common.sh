# Shared constants and helpers for the claude-tracing stack.
#
# [LAW:one-source-of-truth] This file is the only place ports, versions, and paths
# are written down. config/*.yaml read them back via OpenTelemetry's ${env:...}
# expansion rather than restating them, so there is no second copy to drift.
#
# Sourced, never executed.

set -euo pipefail

CT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CT_VAR_DIR="$CT_ROOT/var"
CT_BIN_DIR="$CT_VAR_DIR/bin"
CT_RUN_DIR="$CT_VAR_DIR/run"
CT_LOG_DIR="$CT_VAR_DIR/log"
CT_CONFIG_DIR="$CT_ROOT/config"

# --- ports ------------------------------------------------------------------
# The collector owns the standard OTLP ports; it is the single endpoint Claude
# Code talks to. Jaeger's own OTLP receiver is moved out of the way to 14317.
CT_OTLP_GRPC_PORT=4317          # collector <- claude code (gRPC)
CT_OTLP_HTTP_PORT=4318          # collector <- anything else (HTTP)
CT_COLLECTOR_HEALTH_PORT=13133  # collector readiness
CT_COLLECTOR_TELEMETRY_PORT=8888 # collector's own internal metrics
CT_CLAUDE_METRICS_PORT=8889     # Prometheus scrape surface for Claude's metrics
CT_JAEGER_OTLP_PORT=14317       # jaeger <- collector (traces only)
CT_JAEGER_UI_PORT=16686         # jaeger UI + query API
CT_JAEGER_HEALTH_PORT=13134     # jaeger readiness
CT_JAEGER_TELEMETRY_PORT=18888  # jaeger's own internal metrics
CT_CLICKHOUSE_HTTP_PORT=8123    # clickhouse SQL over HTTP -- what `ct sql` talks to
CT_CLICKHOUSE_NATIVE_PORT=9000  # clickhouse <- collector (native protocol)

# --- the two trace sinks ----------------------------------------------------
# Two sinks, two jobs, no dependency between them. Badger answers "show me this
# trace" for a week; ClickHouse answers "sum tokens by month" for a year. Either
# can be lost without taking the other with it.
CT_CLICKHOUSE_DATA_DIR="$CT_VAR_DIR/clickhouse"
CT_CLICKHOUSE_DATABASE=claude
CT_CLICKHOUSE_TABLE=spans

# The request-grain view over that table: one row per llm_request, carrying what
# it cost and what it had to do with a tool call. Named here rather than spelled
# out at each of its three uses in `ct`, so renaming it is one edit and not four.
#
# Unlike CT_CLICKHOUSE_TABLE above -- which collector.yaml reads as the
# exporter's traces_table_name, and so genuinely configures something -- nothing
# is configured from this. It buys drift protection only, and it does not make
# the name single-sourced: config/clickhouse.yaml still holds the authoritative
# CREATE VIEW. This is the same trade the table makes, held true the same way, by
# a check that fails loudly rather than by trust -- there, ClickHouse's readiness
# query; here, the `ct verify` assertion that queries this view by name.
CT_CLICKHOUSE_REQUESTS_VIEW=llm_requests

# The rate table the request view multiplies token counts against to get dollars.
# Named here on the same terms as the view above -- nothing is configured from
# it, config/clickhouse.yaml still holds the authoritative CREATE VIEW, and the
# `ct verify` assertion that names it is what would fail loudly if the two ever
# disagreed. It is spelled out here rather than inline because the check that
# fires when a model has no rate has to tell you where to add one, and a path in
# an error message is the last place a stale name should be discovered.
CT_CLICKHOUSE_PRICES_VIEW=model_prices

# How long spans survive on disk before badger expires them.
#
# ClickHouse's own retention is not here, and deliberately: it is a TTL clause
# inside the CREATE TABLE in config/clickhouse.yaml, and ClickHouse's config
# substitutes whole values, never substrings of a query. Rather than let this
# file hold a year that the DDL could silently disagree with, the DDL states it
# once and this comment says where to look.
CT_TRACE_TTL=168h

export CT_ROOT CT_VAR_DIR CT_BIN_DIR CT_RUN_DIR CT_LOG_DIR CT_CONFIG_DIR
export CT_OTLP_GRPC_PORT CT_OTLP_HTTP_PORT CT_COLLECTOR_HEALTH_PORT
export CT_COLLECTOR_TELEMETRY_PORT CT_CLAUDE_METRICS_PORT
export CT_JAEGER_OTLP_PORT CT_JAEGER_UI_PORT CT_JAEGER_HEALTH_PORT
export CT_JAEGER_TELEMETRY_PORT CT_TRACE_TTL
export CT_CLICKHOUSE_HTTP_PORT CT_CLICKHOUSE_NATIVE_PORT CT_CLICKHOUSE_DATA_DIR
export CT_CLICKHOUSE_DATABASE CT_CLICKHOUSE_TABLE CT_CLICKHOUSE_REQUESTS_VIEW
export CT_CLICKHOUSE_PRICES_VIEW

# --- pinned tool releases ---------------------------------------------------
CT_JAEGER_VERSION=2.20.0
CT_OTELCOL_VERSION=0.159.0
# The -lts suffix is part of ClickHouse's release tag, not decoration: the
# stable channel moves every few weeks and this store is meant to hold a year.
CT_CLICKHOUSE_VERSION=26.3.21.7-lts

# --- service table ----------------------------------------------------------
# [LAW:one-type-per-behavior] Every service here is the same kind of thing: a
# process to launch, and an HTTP question whose answer means "ready". What
# differs is data, not behavior, so the supervisor iterates this table instead
# of branching per service.
#
# The command line is the row's tail rather than a config path, because the
# three binaries disagree about how to be told where their config is -- jaeger
# and otelcol take `--config X`, clickhouse takes a `server` subcommand and
# `--config-file=X`. Holding argv as data keeps that disagreement in the table,
# where a fourth service is a fourth row and still not a fourth code path.
#
# Order is start order, and it is load-bearing: ClickHouse owns the span table
# and its readiness question is that table answering, so by the time the
# collector starts there is something for it to insert into.
# [LAW:no-ambient-temporal-coupling]
#
# Fields: name|ready-url|argv...
ct_services() {
  cat <<EOF
clickhouse|http://127.0.0.1:$CT_CLICKHOUSE_HTTP_PORT/?query=SELECT+count()+FROM+$CT_CLICKHOUSE_DATABASE.$CT_CLICKHOUSE_TABLE|$CT_BIN_DIR/clickhouse|server|--config-file=$CT_CONFIG_DIR/clickhouse.yaml
jaeger|http://127.0.0.1:$CT_JAEGER_UI_PORT/api/services|$CT_BIN_DIR/jaeger|--config|$CT_CONFIG_DIR/jaeger.yaml
collector|http://127.0.0.1:$CT_COLLECTOR_HEALTH_PORT/|$CT_BIN_DIR/otelcol-contrib|--config|$CT_CONFIG_DIR/collector.yaml
EOF
}

# Applies a handler to every service row, as: handler <name> <ready-url> <argv...>
#
# [LAW:composability] The handler is a value crossing this boundary, which is
# what lets up, down, and status each say what they do to a service without any
# of them restating how the table is parsed.
ct_for_each_service() {
  local handler="$1" row
  local -a field
  while IFS= read -r row; do
    IFS='|' read -r -a field <<<"$row"
    "$handler" "${field[@]}"
  done < <(ct_services)
}

# --- output -----------------------------------------------------------------
ct_info()  { printf '\033[33m%s\033[0m\n' "$*"; }
ct_ok()    { printf '\033[32m%s\033[0m\n' "$*"; }
ct_warn()  { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
ct_trace() { printf '\033[35m%s\033[0m\n' "$*"; }

# [LAW:no-silent-failure] Every abort names what broke and where to look.
ct_die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ct_pidfile() { printf '%s/%s.pid\n' "$CT_RUN_DIR" "$1"; }
ct_logfile() { printf '%s/%s.log\n' "$CT_LOG_DIR" "$1"; }

# --- waiting ----------------------------------------------------------------

# Retries a condition until it holds or the deadline passes; true if it held.
#
# [LAW:no-ambient-temporal-coupling] Every wait in this stack is a wait for a
# stated condition -- a port answering, a table existing, a span arriving, a
# process gone -- and never for an elapsed interval. This is the one place that
# turns a condition into a wait, so no caller is tempted to approximate one
# with a sleep.
#
# Returning false rather than dying is what makes it reusable: what a timeout
# means differs at every call site (a service tails its own log, a missing span
# names the sink to check), so the caller keeps that and only the loop is shared.
CT_POLL_INTERVAL_SECONDS=0.5
ct_poll_until() {
  local seconds="$1" deadline; shift
  deadline=$(( $(date +%s) + seconds ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" && return 0
    sleep "$CT_POLL_INTERVAL_SECONDS"
  done
  return 1
}

# Reports the live pid of a service, or nothing. A pidfile whose process is gone
# is stale, not running -- callers get absence, never a dead pid.
ct_pid_of() {
  local pidfile pid
  pidfile="$(ct_pidfile "$1")"
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile")" || return 0
  # kill -0's stderr is the answer we are computing ("no such process"), not a
  # failure being suppressed -- so discarding it is reading, not silencing.
  if kill -0 "$pid" 2>/dev/null; then printf '%s\n' "$pid"; fi
  return 0
}
