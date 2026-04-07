<p align="center">
  <h1 align="center">toqn</h1>
  <p align="center">Behaviour analytics for developers using coding agents</p>
</p>

<p align="center">
  <a href="https://github.com/toqnlab/toqn/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <a href="https://github.com/toqnlab/toqn/actions"><img src="https://github.com/toqnlab/toqn/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://toqn.dev"><img src="https://img.shields.io/badge/toqn.dev-live-brightgreen" alt="toqn.dev"></a>
</p>

<p align="center">
  Track your AI coding sessions — tokens, tools, costs, and workflow patterns.<br>
  GitHub-style heatmaps. Public profiles. Free.
</p>

---

```bash
curl -fsSL toqn.dev/install | bash
```

---

## Supported Agents

| Agent | Status |
|-------|--------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Supported |
| [Cursor](https://cursor.com) | Supported |
| [Codex](https://openai.com/index/codex/) | Supported |
| [GitHub Copilot](https://github.com/features/copilot) | Supported |

---

## What It Tracks

toqn hooks into your coding agent's lifecycle and extracts **session metadata only** — no code, no conversations, no file contents.

| Metric | Description |
|--------|-------------|
| **Tokens** | Input, output, cache creation, cache read — per turn |
| **Model** | Which model was used (e.g. claude-sonnet-4, gpt-4.1) |
| **Tools** | How often each tool was invoked (Bash, Edit, Read, Write, etc.) |
| **Git operations** | Commits, pushes, PRs created |
| **File operations** | Files touched, grouped by extension |
| **Bash categories** | Semantic grouping: test, build, lint, git_commit, package, etc. |
| **Lines changed** | Lines added and removed |
| **Subagents & skills** | Agent spawns and skill invocations |

### What It Does NOT Track

- **No code content** — never reads your source files
- **No conversations** — never reads your prompts or responses
- **No file contents** — only counts and extensions
- **No secrets** — no access to env vars, credentials, or keys

---

## How It Works

**1. Install the hook** — one command sets up a lightweight shell hook for your agent(s).

**2. Code normally** — the hook fires automatically when a coding session ends. It parses the session transcript for metadata (token counts, tool usage, git operations) and sends a small JSON payload to `toqn.dev/api/ingest/v2`.

**3. See your dashboard** — visit `toqn.dev/username` for GitHub-style heatmaps, model breakdowns, tool frequency charts, cost tracking, streaks, and more.

---

## Dashboard Features

- **Yearly heatmap** — GitHub-style contribution graph for your AI usage
- **Cost tracking** — per model, per day, per month spending breakdown
- **Public profiles** — shareable profile pages at `toqn.dev/username`
- **Streak tracking** — current and longest usage streaks
- **Model breakdown** — which models you use and how much
- **Tool frequency** — which agent tools you rely on most
- **Code velocity** — lines added/removed over time
- **Weekly reports** — email digests with charts and insights
- **Badges** — earn achievements for streaks, milestones, and patterns

---

## Privacy

**toqn never reads your code or conversations.** The hook only extracts aggregate statistics from session metadata — token counts, tool invocation counts, and git operation counts. No source code, prompts, or responses leave your machine.

The hook script is fully open source — read it yourself: [`scripts/toqn-hook.sh`](scripts/toqn-hook.sh)

For more details, see [toqn.dev/privacy](https://toqn.dev/privacy).

---

## Install

### macOS / Linux

```bash
curl -fsSL toqn.dev/install | bash
```

The installer will:
1. Start a device authorization flow (opens your browser to approve)
2. Download the hook script to `~/.toqn/hook.sh`
3. Configure hooks for any detected agents (Claude Code, Cursor, Codex)
4. Save your API key to your shell config

### Windows

```powershell
irm toqn.dev/install/win | iex
```

### Manual install

If you prefer to set things up yourself:

1. Get your API key from [toqn.dev/settings](https://toqn.dev/settings)
2. Add `export TOQN_API_KEY="your-key"` to your shell config
3. Download the hook script: `curl -fsSL toqn.dev/scripts/toqn-hook.sh -o ~/.toqn/hook.sh`
4. Configure your agent's hooks to run `bash ~/.toqn/hook.sh <source>` on session stop

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TOQN_API_KEY` | Yes | Your API key from [toqn.dev/settings](https://toqn.dev/settings) |
| `TOQN_URL` | No | Override the API endpoint (default: `https://toqn.dev`) |
| `TOQN_DEBUG` | No | Set to `1` to log debug info to `/tmp/toqn-debug/` |
| `TOQN_AUTO_UPDATE` | No | Set to `1` to enable automatic hook updates |

---

## Development

### Prerequisites

- [Bun](https://bun.sh) (package manager and test runner)
- [jq](https://jqlang.github.io/jq/) (required by the hook script and tests)

### Running tests

```bash
bun install
bun run test
```

Tests cover:
- **Hook script** — payload extraction for all four agents, edge cases (missing transcripts, no API key, debug mode)
- **Installer** — agent configuration, idempotency, API key management, device auth flow, backwards compatibility

### Shell linting

```bash
shellcheck scripts/install.sh scripts/toqn-hook.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

---

## License

MIT — see [LICENSE](LICENSE).

Built by [toqn.dev](https://toqn.dev)
