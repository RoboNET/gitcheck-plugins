#!/bin/bash
# =============================================================================
# PostToolUse hook — redacts secret patterns from tool output.
#
# Reads tool stdout from stdin, writes redacted output to stdout.
# Logs redaction events to stderr (visible in container logs).
# =============================================================================
set -eo pipefail

REDACTED=0

redact() {
  local PATTERN="$1"
  local LABEL="$2"
  # Count matches before redacting
  local MATCHES
  MATCHES="$(echo "$OUTPUT" | grep -cE "$PATTERN" 2>/dev/null || true)"
  if [ "$MATCHES" -gt 0 ]; then
    OUTPUT="$(echo "$OUTPUT" | sed -E "s/$PATTERN/[REDACTED]/g")"
    REDACTED=$((REDACTED + MATCHES))
    echo "[secret-redactor] Redacted $MATCHES occurrence(s) of $LABEL" >&2
  fi
}

OUTPUT="$(cat)"

# Bearer tokens
redact 'Bearer [A-Za-z0-9._-]{20,}' "Bearer token"

# Anthropic API keys
redact 'sk-ant-[A-Za-z0-9-]{20,}' "Anthropic API key"

# GitHub Personal Access Tokens
redact 'ghp_[A-Za-z0-9]{36}' "GitHub PAT"

# GitHub OAuth tokens
redact 'gho_[A-Za-z0-9]{36}' "GitHub OAuth token"

# Base64-like strings >40 chars after = or : (potential secrets in config)
redact '[=:][[:space:]]*[A-Za-z0-9+/]{40,}[=]{0,2}' "Base64-like secret"

# Emit (possibly redacted) output
echo "$OUTPUT"

if [ "$REDACTED" -gt 0 ]; then
  echo "[secret-redactor] Total redactions: $REDACTED" >&2
fi

exit 0
