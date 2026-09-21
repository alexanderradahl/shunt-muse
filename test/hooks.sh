#!/bin/bash
# Checks the two PreToolUse hooks against a generated large and small file.
# Needs jq. No network, no Muse.
H="$(cd "$(dirname "$0")/../plugins/shunt-muse/hooks" && pwd)"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
seq 1 400 > "$d/big.txt"; seq 1 10 > "$d/small.txt"
fail=0
check() { # hook, expected exit code, json input, label
  echo "$3" | "$H/$1" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$2" ]; then echo "ok   $4"; else echo "FAIL $4 (exit $rc, want $2)"; fail=1; fi
}
check check-file-size 2 "{\"tool_input\":{\"file_path\":\"$d/big.txt\"}}"                 "Read of big file blocked"
check check-file-size 0 "{\"tool_input\":{\"file_path\":\"$d/big.txt\",\"limit\":50}}"    "Read with limit allowed"
check check-file-size 0 "{\"tool_input\":{\"file_path\":\"$d/small.txt\"}}"               "Read of small file allowed"
check check-bash-read 2 "{\"tool_input\":{\"command\":\"cat $d/big.txt\"}}"               "cat of big file blocked"
check check-bash-read 2 "{\"tool_input\":{\"command\":[\"cat\",\"$d/big.txt\"]}}"          "argv-array cat blocked (Codex)"
check check-bash-read 0 "{\"tool_input\":{\"command\":\"cat $d/big.txt | grep 7\"}}"      "piped cat allowed"
check check-bash-read 0 '{"tool_input":{"command":"git status"}}'                        "other commands allowed"
exit $fail
