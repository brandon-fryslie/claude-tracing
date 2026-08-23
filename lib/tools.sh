# Provisioning for the two stack binaries. One job: guarantee that a verified
# jaeger and otelcol-contrib exist under var/bin, or fail loudly saying why.
#
# Sourced by ct, after lib/common.sh.

# [LAW:one-source-of-truth] Both projects publish checksums, but in different
# shapes -- otelcol hashes the tarball, jaeger hashes the extracted files. Rather
# than carry two verification procedures, we pin the sha256 of the *binary we
# actually run*. One procedure, and the pin describes the artifact rather than
# the download that delivered it.
#
# Fields: name|os|arch|url|member|sha256
ct_tool_pins() {
  cat <<EOF
jaeger|darwin|arm64|https://github.com/jaegertracing/jaeger/releases/download/v$CT_JAEGER_VERSION/jaeger-$CT_JAEGER_VERSION-darwin-arm64.tar.gz|jaeger-$CT_JAEGER_VERSION-darwin-arm64/jaeger|810792979f85937984c82a98c0a72d6620fef5928f163dbc6c6c361e4315f778
otelcol-contrib|darwin|arm64|https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$CT_OTELCOL_VERSION/otelcol-contrib_${CT_OTELCOL_VERSION}_darwin_arm64.tar.gz|otelcol-contrib|d8e4d7df01f1de72be76e1f372dd1326482073017cf2264152b18c9f06c0e9f6
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

# Looks up the pin row for a tool on this host. Absence is loud, not empty: an
# unpinned platform must not silently fall through to an unverified download.
ct_pin_for() {
  local tool="$1" os arch line row=""
  os="$(ct_host_os)"; arch="$(ct_host_arch)"
  while IFS= read -r line; do
    case "$line" in "$tool|$os|$arch|"*) row="$line" ;; esac
  done < <(ct_tool_pins)
  [ -n "$row" ] || ct_die "no pinned build of '$tool' for $os/$arch.
  Add a row to ct_tool_pins() in lib/tools.sh: download the release tarball,
  run 'shasum -a 256' on the extracted binary, and pin that hash."
  printf '%s\n' "$row"
}

# Downloads, verifies, and installs one tool. Idempotent: an already-installed
# binary whose hash matches the pin is left alone.
ct_install_tool() {
  local tool="$1" row url member want dest tmp got
  row="$(ct_pin_for "$tool")"
  url="$(printf '%s' "$row" | cut -d'|' -f4)"
  member="$(printf '%s' "$row" | cut -d'|' -f5)"
  want="$(printf '%s' "$row" | cut -d'|' -f6)"
  dest="$CT_BIN_DIR/$tool"

  if [ -x "$dest" ] && [ "$(ct_sha256 "$dest")" = "$want" ]; then
    return 0
  fi

  ct_info "fetching $tool from $url"
  tmp="$CT_VAR_DIR/tmp/$tool"
  rm -rf "$tmp"; mkdir -p "$tmp"

  curl -fsSL --retry 3 -o "$tmp/pkg.tar.gz" "$url" \
    || ct_die "download failed: $url"
  tar xzf "$tmp/pkg.tar.gz" -C "$tmp" "$member" \
    || ct_die "'$member' not found in the $tool tarball -- the release layout changed; update ct_tool_pins()"

  got="$(ct_sha256 "$tmp/$member")"
  [ "$got" = "$want" ] \
    || ct_die "checksum mismatch for $tool
  expected $want
  got      $got
  Refusing to install. Either the release was re-cut or the download is corrupt."

  mkdir -p "$CT_BIN_DIR"
  mv "$tmp/$member" "$dest"
  chmod +x "$dest"
  rm -rf "$tmp"
  ct_ok "installed $tool -> $dest"
}

ct_install_tools() {
  local tool
  for tool in jaeger otelcol-contrib; do
    ct_install_tool "$tool"
  done
}
