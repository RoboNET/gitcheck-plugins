---
id: DOC-035-user
type: documentation
title: User Guide - Agent Reaction to PR Comments
feature: FEAT-035
author: robonet
fields:
  doc_type: user-guide
links:
  belongs_to: [FEAT-035]
  documents: [FEAT-035]
reverse_links: {}
---

# Agent Reaction to PR Comments -- User Guide

## What It Does

When a reviewer leaves a comment on a spec pipeline PR, the Agent Runner detects it within one poll cycle (default 30 seconds), reads the comment, and runs `/spec inbox` to address the feedback. The agent pushes a fix commit and replies on the PR -- no manual intervention required.

This closes the review loop: you comment, the agent fixes, you review the fix.

## How the Comment Reaction Flow Works

```
Reviewer leaves comment on PR
        |
        v
GitHubPoller detects comment count increase (next poll cycle)
        |
        v
Poller fetches latest comment via GitHub API
        |
        v
NormalizedEvent emitted: type=pr.commented
  with CommentBody, CommentAuthor, CommentId
        |
        v
EventRouter matches plugin.yaml rule
  (type: pr.commented, labels: ["spec:*"])
        |
        v
ClaudeExecutor runs: /spec inbox
  (agent reads all unresolved comments, addresses them)
        |
        v
Agent pushes fix commit, replies on PR with commit SHA
```

The entire cycle takes 30-60 seconds depending on the poll interval and the complexity of the requested change.

## Events That Trigger Reactions

Three event types handle the PR review workflow:

| Event | Trigger | Default Action |
|-------|---------|----------------|
| `pr.commented` | New comment on a PR with `spec:*` label | `/spec inbox` |
| `pr.review_submitted` (changes_requested) | Review submitted requesting changes | `/spec inbox` |
| `pr.review_submitted` (approved) | Review approved | `/spec next {FEATURE_ID}` |

All three require the PR to have at least one label matching `spec:*`. Bot-authored comments (author login ending with `[bot]`) are automatically ignored.

**Rate limiting:** At most one `pr.commented` event fires per PR per poll cycle, even if multiple comments were posted between polls. The event carries the latest comment only. The agent can fetch earlier comments via `gh` during its session if needed.

## Comment Context Variables

When a `pr.commented` event matches a plugin rule, two template variables become available for action strings:

| Variable | Description |
|----------|-------------|
| `{COMMENT_BODY}` | Text of the latest new comment. Empty string if the comment fetch failed (e.g., rate limit). |
| `{COMMENT_AUTHOR}` | Login of the comment author. Empty string on fetch failure. |

The default spec-pipeline plugin does not include these variables in the action string because `/spec inbox` reads all unresolved comments itself. They are available for custom plugins that want to pass comment text directly into a prompt.

All existing variables continue to work: `{PR_NUMBER}`, `{FEATURE_ID}`, `{REPO}`.

## gh CLI Restrictions

The Agent Runner restricts which `gh` CLI operations the agent can perform. This prevents the agent from acting outside the scope of the current repository's pull requests, even if a PR comment contains instructions to do so.

### Allowed operations

| Command | Purpose |
|---------|---------|
| `gh pr *` | All PR operations: list, view, create, comment, merge, review |
| `gh api repos/{owner}/{repo}/pulls/*` | PR API calls |
| `gh api repos/{owner}/{repo}/issues/*/comments` | Issue comments on PRs |
| `gh repo clone` | Clone the current repo only (enforced by `GITCHECK_REPO`) |
| `gh auth status` | Read-only auth check (useful for debugging) |

### Blocked operations

| Command | Reason |
|---------|--------|
| `gh repo create`, `gh repo delete`, `gh repo fork` | Prevents creating or destroying repositories |
| `gh ssh-key *`, `gh gpg-key *` | Prevents managing account credentials |
| `gh auth login`, `gh auth logout`, `gh auth switch` | Prevents changing authentication context |
| `gh config set *` | Prevents modifying gh configuration |
| `gh api -X DELETE *`, `gh api --method DELETE *` | Prevents destructive API calls on non-PR endpoints |

These restrictions are enforced at two levels: Claude Code `permissions.deny` rules in `settings.json`, and the `secret-guard.sh` PreToolUse hook. Both must pass for a command to execute.

## Security Model

The agent processes PR comments as untrusted input. Seven layers of defense prevent comment content from causing harm:

1. **Sandbox filesystem** -- `denyRead` blocks access to `.env`, `*.pem`, `*.key`, `*credential*`, and `/proc/*/environ`. A comment saying "read .env" hits a hard block.

2. **Permissions deny** -- Commands like `env`, `printenv`, `export`, and `cat .env` are blocked at the Claude Code permission layer before they reach the shell.

3. **Network allowlist** -- Outbound connections are restricted to `github.com`, `api.github.com`, and `api.anthropic.com`. Data exfiltration to external hosts is impossible.

4. **PreToolUse hook (`secret-guard.sh`)** -- Inspects every tool call before execution. Blocks reads of secret files, env-dumping commands, secret variable references, and dangerous `gh` subcommands.

5. **PostToolUse hook (`secret-redactor.sh`)** -- Scans tool output after execution for token patterns (`ghp_*`, `sk-ant-*`, `Bearer *`, etc.) and replaces matches with `[REDACTED]`.

6. **Branch protection** -- The agent works in a feature branch and creates PRs for review. It cannot push to `main` directly. All changes require human approval.

7. **`gh` CLI scope restriction** -- The agent can only interact with the current repo's PRs. Repository management, credential operations, and destructive API calls are blocked (see section above).

**What a comment can influence:** which files the agent edits, what changes it proposes. All changes go through a PR that the reviewer approves.

**What a comment cannot do:** read secrets, access external services, push to main, delete branches, modify security hooks, create or destroy repositories, manage SSH keys.

## Customizing Comment Reactions in plugin.yaml

The default spec-pipeline plugin handles `pr.commented` with `/spec inbox`. You can add your own rules or override the behavior.

### Default rule (from gitcheck-plugins)

```yaml
events:
  - type: pr.commented
    labels: ["spec:*"]
    action: "/spec inbox"
```

### Custom rule with comment context

To pass the comment body directly into a custom action:

```yaml
events:
  - type: pr.commented
    labels: ["review:*"]
    action: "/my-review-skill fix --comment \"{COMMENT_BODY}\" --author {COMMENT_AUTHOR}"
```

### Multiple label patterns

You can have separate rules for different label patterns. The router uses first-match, so order matters:

```yaml
events:
  - type: pr.commented
    labels: ["spec:implementation"]
    action: "/spec inbox --focus code"

  - type: pr.commented
    labels: ["spec:*"]
    action: "/spec inbox"
```

A comment on a PR with `spec:implementation` matches the first rule. A comment on a PR with `spec:requirements` matches the second.

### Repo-local plugin

Place your plugin in `<repo>/.claude/skills/<name>/plugin.yaml` to add project-specific comment handling without publishing to the marketplace:

```
.claude/
  skills/
    my-review-bot/
      SKILL.md          # skill definition
      plugin.yaml       # event routing rules
```

## Troubleshooting

### Agent does not react to PR comments

1. **Check that the PR has a `spec:*` label.** Only PRs with labels matching the plugin's label filter trigger events. Run `gh pr view <number> --json labels` to verify.

2. **Check that the comment author is not a bot.** Comments from accounts ending with `[bot]` are ignored. The agent also ignores its own comments to avoid feedback loops.

3. **Check the plugin routing table.** Run the following inside the container to verify `pr.commented` rules exist:
   ```bash
   docker exec gitcheck-agent gitcheck listen --plugins
   ```
   If no `pr.commented` rule appears, the plugin is missing or has a YAML syntax error.

4. **Check the poll interval.** The agent only checks for new comments once per poll cycle (default 30 seconds). If the comment was posted within the last cycle, wait for the next poll.

5. **Check the container logs.** Look for event detection and routing output:
   ```bash
   docker compose logs --tail 50 gitcheck-agent
   ```
   You should see lines like `Event: Commented PR#N` when a comment is detected.

6. **Check listener state.** If the event was already processed (from a previous run or restart), it will not fire again. Inspect the state file:
   ```bash
   docker exec gitcheck-agent cat /home/gitcheck-runner/.gitcheck/listener-state.json | jq .
   ```

### gh commands are blocked unexpectedly

The `secret-guard.sh` hook and `permissions.deny` rules block dangerous `gh` operations. If a legitimate command is blocked:

1. **Check the security audit log** for the exact block reason:
   ```bash
   docker exec gitcheck-agent cat /home/gitcheck-runner/.gitcheck/security-audit.log
   ```

2. **Verify the command is in the allowed list.** Only `gh pr *`, `gh api` for PR/issue endpoints, `gh repo clone`, and `gh auth status` are allowed. Other `gh` subcommands are blocked by design.

3. **If you need a custom `gh` command**, add it to your plugin's `hooks/` directory as an override. Plugin hooks are merged with the base hooks, not replaced.

### Comment fetch failed -- agent runs without context

If the GitHub API returns an error when fetching the latest comment (rate limit, transient network issue), the event still fires with `CommentBody` set to null. The agent falls back to reading comments via `gh pr view` during its session. Check container logs for `comment fetch failed` warnings.

### Agent reacts to old comments after restart

Without persistent volume mounts, the agent loses its `listener-state.json` and may reprocess recent events including comments. Mount `/home/gitcheck-runner/.gitcheck/` as a volume to preserve state across restarts. See the Docker Compose example in the Agent Runner user guide (DOC-033-user).
