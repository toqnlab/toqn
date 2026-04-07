# Contributing to toqn

Thanks for your interest in contributing!

## Getting Started

### Prerequisites

- [Bun](https://bun.sh) — package manager and test runner
- [jq](https://jqlang.github.io/jq/) — required by the hook script and tests
- [ShellCheck](https://www.shellcheck.net/) — for shell script linting (optional)

### Setup

```bash
git clone https://github.com/toqnlab/toqn.git
cd toqn
bun install
```

### Running Tests

```bash
bun run test
```

All tests must pass before submitting a PR.

### Shell Linting

```bash
shellcheck scripts/install.sh scripts/toqn-hook.sh
```

## Pull Requests

1. Fork the repo and create your branch from `main`
2. Add tests for any new functionality
3. Ensure all tests pass
4. Open a pull request with a clear description

## Reporting Issues

Open an issue on GitHub with:
- What you expected to happen
- What actually happened
- Your OS and agent (Claude Code, Cursor, etc.)
- Debug logs if available (`TOQN_DEBUG=1`)
