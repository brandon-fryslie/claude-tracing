# Turns the directory Claude is about to run in into OTel resource attributes.
# One job: answer "what work was this session for" in a form a query can group by.
#
# Claude Code's own attributes describe the *session* -- model, tokens, timings,
# identity -- and say nothing about the *work*. So "average turns to finish a
# ticket" and "does review converge faster on Opus 5" have no key to group by,
# and no storage engine fixes that later: an attribute that was never emitted
# cannot be backfilled.
#
# Sourced by ct, after lib/common.sh.

# --- probes -----------------------------------------------------------------
# A probe prints one fact about here, or nothing when the fact does not apply.
# Nothing is a real answer, not a failure: claude runs in plenty of directories
# that are not git checkouts. Git reports that on stderr and exits non-zero, so
# discarding both is reading the answer we asked for -- the same move ct_pid_of
# makes with kill -0 -- rather than a failure being hidden.

ct_probe_repo_name() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  basename "$toplevel"
}

# Empty on a detached HEAD, which is the truth: there is no branch to name.
ct_probe_branch() { git branch --show-current 2>/dev/null || return 0; }

ct_probe_cwd() { printf '%s\n' "$PWD"; }

# What the session is FOR, which is the one work-unit fact nothing here can
# derive: two sessions in the same checkout on the same branch, one writing the
# change and one reviewing it, are identical to every probe above. So this one
# reads the answer from the environment -- the only place the fact exists at
# launch -- and, like the others, prints nothing when there is nothing to say.
#
# [LAW:no-mode-explosion] A purpose, not a `review=true`. A boolean answers one
# question and forces a new attribute for the next category, which means a new
# column and an edit to every query that groups by category. A purpose admits
# categories as data: "were the docs sessions cheaper" costs a new VALUE and no
# change to this file, the schema, or any query already written.
ct_probe_session_purpose() { printf '%s\n' "${CT_SESSION_PURPOSE:-}"; }

# --- the label set ----------------------------------------------------------
# [LAW:one-type-per-behavior] Every row is the same kind of thing -- a key, and
# something that prints its value -- so adding a label is adding a row, never a
# code path. That is the property this table has to keep: ticket .6 joins lit
# tickets to sessions, and it should cost one line here and nothing else.
#
# The keys are OpenTelemetry semantic conventions rather than local coinages.
# A year of recorded history is expensive to rename, and vcs.* / process.* are
# already understood by anything else that reads OTel.
#
# `session.purpose` is a coinage where the other three are OTel semantic
# conventions, because the conventions have no key for it. It is named to sit
# beside `session.id`, which Claude Code already stamps on every span: same
# subject, one asking which session and one asking what for.
#
# Fields: attribute-key|probe
ct_label_probes() {
  cat <<'EOF'
session.purpose|ct_probe_session_purpose
vcs.repository.name|ct_probe_repo_name
vcs.ref.head.name|ct_probe_branch
process.working_directory|ct_probe_cwd
EOF
}

# --- encoding ---------------------------------------------------------------

# Percent-encoding, byte-wise. Unreserved characters plus ':' and '/' stay
# literal so paths and branch names remain readable in the Jaeger UI; every
# other byte becomes %XX. LC_ALL=C is what makes the walk byte-wise, which gives
# multi-byte UTF-8 one escape per byte instead of one mangled escape per
# character. Over-encoding is safe for both consumers -- W3C baggage values and
# URL query components -- so the conservative allowlist serves both.
ct_percent_encode() {
  local LC_ALL=C value="$1" out='' i char
  for (( i = 0; i < ${#value}; i++ )); do
    char="${value:i:1}"
    case "$char" in
      [A-Za-z0-9._~:/-]) out="$out$char" ;;
      *) printf -v char '%%%02X' "'$char"; out="$out$char" ;;
    esac
  done
  printf '%s' "$out"
}

# --- rendering --------------------------------------------------------------

# Runs every probe and renders the ones that apply, comma-joined, in whatever
# format the caller names.
#
# [LAW:dataflow-not-control-flow] The `if` is a filter over values, not a branch
# over structure: every probe runs on every call, and one with nothing to say
# drops out of the list rather than stamping an empty value. An absent attribute
# reads as "does not apply here"; `vcs.ref.head.name=` reads as a branch whose
# name is the empty string -- an answer-shaped void that no later query could
# tell apart from a real branch.
#
# [LAW:composability] The format is a value crossing this boundary, not a second
# copy of the loop. That is what lets `ct verify` ask Jaeger for exactly the
# labels this run stamped, in Jaeger's own query syntax, without this file
# learning that Jaeger exists -- and without the expectation and the stamp
# drifting apart, since both are this one iteration over this one table.
ct_join_labels() {
  local format="$1" key probe value out='' separator=''
  while IFS='|' read -r key probe; do
    value="$("$probe")"
    if [ -n "$value" ]; then
      out="$out$separator$("$format" "$key" "$value")"
      separator=','
    fi
  done < <(ct_label_probes)
  printf '%s' "$out"
}

ct_label_as_baggage() { printf '%s=%s' "$1" "$(ct_percent_encode "$2")"; }

# The work-unit labels for here, as OTEL_RESOURCE_ATTRIBUTES entries.
ct_work_labels() { ct_join_labels ct_label_as_baggage; }

# --- the attribute string ---------------------------------------------------

# [LAW:parse-dont-validate] The border. Everything upstream is arbitrary text --
# the caller's own OTEL_RESOURCE_ATTRIBUTES, plus branch names and paths -- and
# everything downstream is a comma-separated grammar where an unencoded value
# does not merely look untidy, it changes how many attributes the receiver
# believes it was sent. What comes out of here is a string that survives that
# grammar; nothing downstream re-checks it, because there is nothing left to
# check.
#
# The failure arm is loud for a measured reason. On Claude Code 2.1.226, a
# string carrying one raw space arrives with *every* attribute missing --
# including the well-formed ones beside it. No partial parse, no complaint, no
# labels. [LAW:no-silent-failure] Since we know that, letting whitespace through
# would be choosing the silence on the user's behalf.
#
# The caller's own entries are passed through untouched and come first: they are
# already in the SDK's format, and re-encoding them would turn a correct %20
# into a literal %2520. That passthrough is the general seam for labelling a
# session with anything this repo has no probe for; the one such fact the epic
# actually needed -- what the session is for -- has its own probe above rather
# than living out here, so that setting it is a variable and not a grammar.
ct_resource_attributes() {
  local inherited="$1" merged
  merged="${inherited:+$inherited,}$(ct_work_labels)"
  case "$merged" in
    *[[:space:]]*)
      ct_die "OTEL_RESOURCE_ATTRIBUTES would contain whitespace, and Claude Code
  responds to that by dropping every attribute in the string -- silently, so the
  session would look labelled and carry nothing. Percent-encode the value
  (space is %20) and try again:
    $merged" ;;
  esac
  printf '%s' "$merged"
}
