# GitCheck Plugins

Claude Code plugin marketplace for [GitCheck Agent Runner](https://github.com/RoboNET/GitCheck).

## Install

```bash
claude /install-skill https://github.com/RoboNET/gitcheck-plugins
```

## Included plugins

### spec-pipeline

Automatically advances spec document pipeline steps when PRs are merged:

| PR Event | Label | Action |
|----------|-------|--------|
| Merged | `spec:requirements` | `/spec next` — generate next step |
| Merged | `spec:architecture` | `/spec next` — generate next step |
| Merged | `spec:test-cases` | `/spec next` — generate next step |
| Merged | `spec:implementation` | `/spec next` — generate next step |
| Merged | `spec:documentation` | `/spec next` — generate next step |
| Merged | `spec:execution` | `/spec next` — generate next step |
| Review: changes requested | `spec:*` | `/spec inbox` — address comments |
| PR opened | `spec:*` | `/spec status` — log state |

### Security hooks

- `secret-guard.sh` — PreToolUse hook that blocks reads of `.env`, credentials, keys
- `secret-redactor.sh` — PostToolUse hook that masks tokens in tool output

## For Agent Runner

When running inside the GitCheck Agent Runner Docker container, the `plugin.yaml` event manifest is auto-discovered at startup. The listener routes PR events to the actions defined above.

## Structure

```
gitcheck-plugins/
├── .claude-plugin/
│   ├── plugin.json         # Claude Code plugin metadata
│   └── marketplace.json    # Marketplace registry
├── skills/
│   └── spec/
│       └── SKILL.md        # /spec skill (universal pipeline operations)
├── hooks/
│   ├── secret-guard.sh     # PreToolUse security hook
│   └── secret-redactor.sh  # PostToolUse security hook
├── prompts/
│   └── base-agent.md       # Base prompt for autonomous agent mode
├── plugin.yaml             # Event routing manifest for Agent Runner
└── README.md
```

## License

MIT
