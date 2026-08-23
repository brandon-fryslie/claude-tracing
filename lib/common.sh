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

# How long spans survive on disk before badger expires them.
CT_TRACE_TTL=168h

export CT_ROOT CT_VAR_DIR CT_BIN_DIR CT_RUN_DIR CT_LOG_DIR CT_CONFIG_DIR
export CT_OTLP_GRPC_PORT CT_OTLP_HTTP_PORT CT_COLLECTOR_HEALTH_PORT
export CT_COLLECTOR_TELEMETRY_PORT CT_CLAUDE_METRICS_PORT
export CT_JAEGER_OTLP_PORT CT_JAEGER_UI_PORT CT_JAEGER_HEALTH_PORT
export CT_JAEGER_TELEMETRY_PORT CT_TRACE_TTL

# --- pinned tool releases ---------------------------------------------------
CT_JAEGER_VERSION=2.20.0
CT_OTELCOL_VERSION=0.159.0

# --- service table ----------------------------------------------------------
# [LAW:one-type-per-behavior] jaeger v2 IS an OpenTelemetry Collector
# distribution, so both services are the same type of thing: a binary that takes
# --config and answers an HTTP readiness probe. What differs is data, not
# behavior, so the supervisor iterates this table instead of branching per
# service. Order is start order: the trace sink comes up before its producer.
#
# Fields: name|binary|config|ready-url
ct_services() {
  cat <<EOF
jaeger|$CT_BIN_DIR/jaeger|$CT_CONFIG_DIR/jaeger.yaml|http://127.0.0.1:$CT_JAEGER_UI_PORT/api/services
collector|$CT_BIN_DIR/otelcol-contrib|$CT_CONFIG_DIR/collector.yaml|http://127.0.0.1:$CT_COLLECTOR_HEALTH_PORT/
EOF
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
