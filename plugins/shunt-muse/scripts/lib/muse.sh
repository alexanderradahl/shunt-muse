#!/bin/bash
# Muse transport for shunt: replaces the Portal AiKA plumbing (aika.sh) with
# one headless `muse exec` turn. Same function names, so bulk-read and
# code-write only change their source line.
#
# The corpus goes into a prompt file, so there is no ARG_MAX ceiling; the
# payload cap below just keeps a single call inside Muse's context.

SHUNT_MAX_PAYLOAD_BYTES="${SHUNT_MAX_PAYLOAD_BYTES:-600000}"
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-300}"
SHUNT_MUSE_BIN="${SHUNT_MUSE_BIN:-muse}"
SHUNT_MUSE_MODEL="${SHUNT_MUSE_MODEL:-muse-spark-1.3-contributor}"
# xhigh measured ~30s on a 1,055-line read (low: ~25s); lower it if speed matters more.
SHUNT_MUSE_EFFORT="${SHUNT_MUSE_EFFORT:-xhigh}"

# The two AiKA modes' instructions, carried in the prompt instead of server-side.
SHUNT_MODE_bulk_reader="You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
SHUNT_MODE_code_writer="You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."

SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -rf "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

shunt_preflight() {
  if ! command -v "$SHUNT_MUSE_BIN" >/dev/null 2>&1; then
    echo "Error: $SHUNT_MUSE_BIN not found. Install Muse Code or set SHUNT_MUSE_BIN." >&2
    return 1
  fi
}

# Runs one headless Muse turn under a mode's instructions and prints the answer.
#   $1 mode name (bulk-reader | code-writer)
#   $2 file holding the message
shunt_invoke() {
  local mode_name="$1" message_file="$2"
  local var="SHUNT_MODE_${mode_name//-/_}" prompt_file workdir err_file out_file bytes rc

  bytes=$(wc -c < "$message_file" | tr -d ' ')
  if [ "$bytes" -gt "$SHUNT_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: request is $bytes bytes, over the $SHUNT_MAX_PAYLOAD_BYTES byte limit. Split into smaller batches." >&2
    return 1
  fi

  shunt_tmpfile prompt_file || return 1
  shunt_tmpfile err_file || return 1
  shunt_tmpfile out_file || return 1
  # Empty, trusted workspace: everything Muse needs is inline, so it gets
  # nothing to wander into and never stalls on a trust prompt.
  workdir=$(mktemp -d) || return 1
  SHUNT_TMPFILES+=("$workdir")

  {
    printf '%s\n\n' "${!var}"
    printf 'Everything you need is below. Do not call tools; answer directly.\n\n'
    cat "$message_file"
  } > "$prompt_file"

  # macOS ships no timeout(1); perl's alarm is the portable stand-in.
  perl -e 'alarm shift; exec @ARGV or die' "$SHUNT_TIMEOUT_SECONDS" \
    "$SHUNT_MUSE_BIN" exec --prompt-file "$prompt_file" \
      --model "$SHUNT_MUSE_MODEL" --reasoning-effort "$SHUNT_MUSE_EFFORT" \
      --max-model-steps 1 --workspace "$workdir" --trust-workspace \
      >"$out_file" 2>"$err_file"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 142 ]; then
      echo "Error: muse exec exceeded ${SHUNT_TIMEOUT_SECONDS}s. Raise SHUNT_TIMEOUT_SECONDS or split the work." >&2
    else
      echo "Error: muse exec failed (exit $rc):" >&2
      grep -v '^muse:   ' "$err_file" | tail -15 >&2
    fi
    return 1
  fi

  if ! grep -q '[^[:space:]]' "$out_file"; then
    echo "Error: muse exec returned no answer." >&2
    grep -v '^muse:   ' "$err_file" | tail -15 >&2
    return 1
  fi
  cat "$out_file"
}
