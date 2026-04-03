#!/bin/bash
# =============================================================================
# PreToolUse hook — blocks tool calls that attempt to read secrets or
# exfiltrate environment variables.
#
# Receives JSON on stdin:  { "tool_name": "...", "tool_input": { ... } }
# Exit 0 = allow, Exit 2 = block tool execution.
# =============================================================================
set -eo pipefail

INPUT="$(cat)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
TOOL_INPUT="$(echo "$INPUT" | jq -c '.tool_input // {}')"

block() {
  echo "[secret-guard] BLOCKED $TOOL_NAME: $1" >&2
  exit 2
}

# ---- Read tool: block access to secret files --------------------------------
if [ "$TOOL_NAME" = "Read" ]; then
  FILE_PATH="$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')"
  case "$FILE_PATH" in
    *.env|*.env.*)              block "reading .env file: $FILE_PATH" ;;
    *credential*|*Credential*)  block "reading credential file: $FILE_PATH" ;;
    *.pem)                      block "reading PEM file: $FILE_PATH" ;;
    *.key)                      block "reading key file: $FILE_PATH" ;;
  esac
fi

# ---- Bash tool: block environment variable exfiltration ---------------------
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND="$(echo "$TOOL_INPUT" | jq -r '.command // empty')"

  # Check for env-dumping commands (word boundaries via grep -qwE)
  if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|)(env|printenv|export)(\s|$|;|&&|\|)'; then
    block "env-dumping command detected"
  fi

  # Check for direct .env reads
  if echo "$COMMAND" | grep -qE 'cat\s+\.env|cat\s+"?\.env'; then
    block "reading .env via cat"
  fi

  # Check for secret variable references
  if echo "$COMMAND" | grep -qE '\$\{?(GITHUB_TOKEN|ANTHROPIC_API_KEY|GITCHECK_[A-Z_]+)\}?'; then
    block "referencing secret variable in command"
  fi
fi

# ---- Grep / Glob tools: block secret file discovery -------------------------
if [ "$TOOL_NAME" = "Grep" ] || [ "$TOOL_NAME" = "Glob" ]; then
  PATTERN="$(echo "$TOOL_INPUT" | jq -r '.pattern // empty')"
  GLOB="$(echo "$TOOL_INPUT" | jq -r '.glob // empty')"
  PATH_ARG="$(echo "$TOOL_INPUT" | jq -r '.path // empty')"

  for VALUE in "$PATTERN" "$GLOB" "$PATH_ARG"; do
    case "$VALUE" in
      *.env*|*credential*|*Credential*|*secret*|*Secret*)
        block "targeting secret pattern: $VALUE" ;;
    esac
  done
fi

# ---- Default: allow --------------------------------------------------------
exit 0
