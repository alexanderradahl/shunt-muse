# shunt-muse

Keep big files out of your coding agent's context. When Claude Code or Codex tries to read a large file in full, a hook stops it and points it at a skill that hands the files to a cheaper model (Muse Spark via `muse exec`). Only the short answer comes back into the session.

This is a fork of Spotify's [shunt](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt). The original delegates to AiKA modes on a Spotify Portal instance. If you don't have Portal, this version does the same thing with the Muse CLI you already have installed.

## What it does

- **Hooks** (`PreToolUse`) block a full `Read`, or a bare `cat`/`head`/`tail`/`less`/`more`, of any file over 350 lines. Reads with an offset or limit, piped commands and small files go through untouched.
- **`bulk-read`** sends one or more files plus a question to Muse and prints the answer.
- **`code-write`** sends a spec plus a reference file to Muse and writes the generated file (tests, config, stubs).
- **Skills** (`bulk-reader`, `code-writer`) tell the agent when to call the scripts.

Every call is one shot. A follow-up question sends the files again, which costs nothing in your agent's context because they never enter it.

## Numbers

One run on a 617-line test file: about 4,800 tokens went to Muse and roughly 300 came back, in 24 seconds at `low` effort. At the default `xhigh`, a 1,055-line file took about 30 seconds and every cited line number was exact. Spotify reports 82-94% savings with the original plugin on a 162K-line Java monorepo; I haven't reproduced that here.

## Requirements

- Muse Code (`muse`) with `muse exec` working headless
- `jq` and `perl` (both ship with macOS)
- Claude Code with plugin support, and/or Codex CLI with hooks enabled

## Install in Claude Code

```sh
claude plugin marketplace add alexanderradahl/shunt-muse
claude plugin install shunt-muse@muse-shunt
```

Start a new session. The skills show up as `shunt-muse:bulk-reader` and `shunt-muse:code-writer`.

## Install in Codex

Clone the repo somewhere stable, then add the Bash hook to `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|shell|exec_command|local_shell",
        "hooks": [
          { "type": "command", "command": "/path/to/shunt-muse/plugins/shunt-muse/hooks/check-bash-read", "timeout": 10 }
        ]
      }
    ]
  }
}
```

Copy the two skills into `~/.codex/skills/` and replace `${CLAUDE_PLUGIN_ROOT}` with the plugin path:

```sh
P=/path/to/shunt-muse/plugins/shunt-muse
for s in bulk-reader code-writer; do
  mkdir -p ~/.codex/skills/$s
  sed "s#\${CLAUDE_PLUGIN_ROOT}#$P#g" $P/skills/$s/SKILL.md > ~/.codex/skills/$s/SKILL.md
done
```

Codex may ask you to approve the new hook the first time it runs. If your Codex sandbox has network access turned off, `bulk-read` can't reach Muse from inside it.

## Configuration

Environment variables:

| Variable | Default | What it does |
| --- | --- | --- |
| `SHUNT_MIN_LINES` | `350` | Files longer than this get blocked |
| `SHUNT_MUSE_MODEL` | `muse-spark-1.3-contributor` | Model passed to `muse exec --model` |
| `SHUNT_MUSE_EFFORT` | `xhigh` | `--reasoning-effort`; lower it (e.g. `low`) for faster reads |
| `SHUNT_TIMEOUT_SECONDS` | `300` | Kill a Muse call after this long |
| `SHUNT_MAX_PAYLOAD_BYTES` | `600000` | Refuse requests bigger than this; split them instead |
| `SHUNT_MUSE_BIN` | `muse` | Path to the Muse binary |

## How the Muse call works

`scripts/lib/muse.sh` writes the mode instructions and the files into a prompt file and runs:

```sh
muse exec --prompt-file <prompt> --model "$SHUNT_MUSE_MODEL" \
  --reasoning-effort "$SHUNT_MUSE_EFFORT" --max-model-steps 1 \
  --workspace <empty temp dir> --trust-workspace
```

The workspace is an empty temp directory, so Muse has nothing to explore and never stops at a trust prompt. One model step is enough because everything it needs is in the prompt.

Your files go to whichever provider Muse is configured for. Check that your tier's data terms fit what you're sending.

## What it won't delegate

Same rules as the original: debugging, editing (the agent needs exact text, so it reads the section it needs with offset/limit) and architecture calls stay with your main model. Only bulk reading and predictable boilerplate go to Muse.

## Tests

```sh
test/hooks.sh
```

Checks both hooks against generated files. No network needed.

## License

Apache 2.0, same as upstream. See [NOTICE](NOTICE) for what changed from Spotify's version.
