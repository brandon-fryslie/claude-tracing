# Provisioning for the stack binaries. One job: guarantee that a verified copy
# of every binary the service table names exists under var/bin, or fail loudly
# saying why.
#
# Sourced by ct, after lib/common.sh.

# [LAW:one-source-of-truth] The three projects publish checksums in three
# shapes -- otelcol hashes the tarball, jaeger hashes the extracted files,
# ClickHouse ships a bare binary with no tarball at all. Rather than carry three
# verification procedures, we pin the sha256 of *what we install*: whatever the
# extract filter below produces. One procedure, and the pin describes a binary
# rather than whichever packaging happened to deliver it.
#
# `extract` is a filter: it reads the downloaded bytes on stdin and writes the
# binary on stdout. That is what lets a tarball member and a bare binary be the
# same kind of row -- `cat` is the identity unpacking, not a special case -- so
# a project that publishes a zip tomorrow is a new value in this column and not
# a branch in ct_install_tool. [LAW:dataflow-not-control-flow]
#
# Fields: name|os|arch|url|extract|sha256
ct_tool_pins() {
  cat <<EOF
jaeger|darwin|arm64|https://github.com/jaegertracing/jaeger/releases/download/v$CT_JAEGER_VERSION/jaeger-$CT_JAEGER_VERSION-darwin-arm64.tar.gz|tar xzOf - jaeger-$CT_JAEGER_VERSION-darwin-arm64/jaeger|810792979f85937984c82a98c0a72d6620fef5928f163dbc6c6c361e4315f778
otelcol-contrib|darwin|arm64|https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$CT_OTELCOL_VERSION/otelcol-contrib_${CT_OTELCOL_VERSION}_darwin_arm64.tar.gz|tar xzOf - otelcol-contrib|d8e4d7df01f1de72be76e1f372dd1326482073017cf2264152b18c9f06c0e9f6
clickhouse|darwin|arm64|https://github.com/ClickHouse/ClickHouse/releases/download/v$CT_CLICKHOUSE_VERSION/clickhouse-macos-aarch64|cat|90c02369d854ab0cbea7ca07214a94322f900e93113bf25977900063a32e929b
EOF
}

ct_host_os()   { uname -s | tr '[:upper:]' '[:lower:]'; }
ct_host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64\n' ;;
    x86_64|amd64)  printf 'amd64\n' ;;
    *)             printf '%s\n' "$(uname -m)" ;;
  esac
}

ct_sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# What an installed binary was verified as when it was installed, or nothing.
#
# [LAW:parse-dont-validate] The pin is checked once, against the bytes that came
# off the network, and the outcome is kept as a stamp beside the binary rather
# than thrown away and re-derived later by re-hashing the file. Re-deriving it
# is what a validator would do, and here it is not merely wasteful, it is wrong:
# ClickHouse ships self-extracting and decompresses itself in place the first
# time it runs -- measured, 161 MB becomes 855 MB and the hash changes forever --
# so the file that is running is never the file that was downloaded. Hashing it
# would report a mismatch on every start and re-download 161 MB to "fix" it.
ct_verified_pin() {
  local stamp="$1.verified"
  [ -f "$stamp" ] || return 0
  cat "$stamp"
}

# Looks up the pin row for a tool on this host. Absence is loud, not empty: an
# unpinned platform must not silently fall through to an unverified download.
ct_pin_for() {
  local tool="$1" os arch line row=""
  os="$(ct_host_os)"; arch="$(ct_host_arch)"
  while IFS= read -r line; do
    case "$line" in "$tool|$os|$arch|"*) row="$line" ;; esac
  done < <(ct_tool_pins)
  [ -n "$row" ] || ct_die "no pinned build of '$tool' for $os/$arch.
  Add a row to ct_tool_pins() in lib/tools.sh: download the release artifact,
  pipe it through the extract filter the row will use, run 'shasum -a 256' on
  what comes out, and pin that hash."
  printf '%s\n' "$row"
}

# Downloads, verifies, and installs one tool. Idempotent: a binary already
# stamped with this pin is left alone.
#
# The download is piped straight through the extract filter into a staging file,
# so there is no archive to write, find, and clean up afterwards. `$extract` is
# unquoted on purpose: the field is a command line, the same way lib/labels.sh
# carries function names as data. It comes from this repo's own table and never
# from a caller.
ct_install_tool() {
  local tool="$1" row url extract want dest staged got
  row="$(ct_pin_for "$tool")"
  url="$(printf '%s' "$row" | cut -d'|' -f4)"
  extract="$(printf '%s' "$row" | cut -d'|' -f5)"
  want="$(printf '%s' "$row" | cut -d'|' -f6)"
  dest="$CT_BIN_DIR/$tool"

  if [ -x "$dest" ] && [ "$(ct_verified_pin "$dest")" = "$want" ]; then
    return 0
  fi

  ct_info "fetching $tool from $url"
  mkdir -p "$CT_BIN_DIR"
  staged="$dest.incoming"

  # [LAW:no-silent-failure] pipefail is what makes a failed download visible: a
  # 404 body extracts to an empty file that would otherwise reach the checksum
  # as a merely-wrong hash, reporting corruption when the truth is a dead URL.
  ( set -o pipefail; curl -fsSL --retry 3 "$url" | $extract > "$staged" ) \
    || { rm -f "$staged"; ct_die "could not fetch and unpack $tool from $url
  The release layout may have changed -- check the url and extract fields in
  ct_tool_pins() in lib/tools.sh."; }

  got="$(ct_sha256 "$staged")"
  [ "$got" = "$want" ] \
    || { rm -f "$staged"; ct_die "checksum mismatch for $tool
  expected $want
  got      $got
  Refusing to install. Either the release was re-cut or the download is corrupt."; }

  chmod +x "$staged"
  mv "$staged" "$dest"
  # Stamped only after the move, so an interrupted install leaves no claim that
  # a binary was verified. [LAW:no-silent-failure]
  printf '%s\n' "$want" > "$dest.verified"
  ct_ok "installed $tool -> $dest"
}

# [LAW:one-source-of-truth] The tools to install are the binaries the service
# table says we are about to run, read back from it rather than listed again
# here. Adding a service is one row, and it provisions itself.
ct_install_tools() {
  ct_for_each_service ct_install_service_binary
}

# A service-row handler, so it takes the whole row and uses the one field it
# needs: the binary is argv[0], and its basename is the tool name to install.
ct_install_service_binary() {
  local bin="$3"
  ct_install_tool "$(basename "$bin")"
}
