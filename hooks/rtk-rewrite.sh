#!/bin/bash
# RTK auto-rewrite hook for Claude Code PreToolUse:Bash
# Transparently rewrites raw commands to their rtk equivalents.
# Outputs JSON with updatedInput to modify the command before execution.

# Guards: skip silently if dependencies missing
if ! command -v rtk &>/dev/null || ! command -v jq &>/dev/null; then
  exit 0
fi

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Extract the first meaningful command (before pipes, &&, etc.)
# We only rewrite if the FIRST command in a chain matches.
FIRST_CMD="$CMD"

# Strip accidental rtk proxy on commands that should bypass rtk (docker exec, psql, etc.)
case "$FIRST_CMD" in
  rtk\ proxy\ docker\ exec\ *)
    STRIPPED=$(echo "$CMD" | sed 's/^rtk proxy //')
    ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
    UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$STRIPPED" '.command = $cmd')
    jq -n --argjson updated "$UPDATED_INPUT" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"RTK strip: docker exec bypasses rtk","updatedInput":$updated}}'
    exit 0
    ;;
esac

# Skip if already using rtk
case "$FIRST_CMD" in
  rtk\ *|*/rtk\ *) exit 0 ;;
esac

# Skip commands with heredocs, variable assignments as the whole command, etc.
case "$FIRST_CMD" in
  *'<<'*) exit 0 ;;
esac

# Strip leading env var assignments for pattern matching
# e.g., "TEST_SESSION_ID=2 npx playwright test" → match against "npx playwright test"
# but preserve them in the rewritten command for execution.
ENV_PREFIX=$(echo "$FIRST_CMD" | grep -oE '^([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)+' || echo "")
if [ -n "$ENV_PREFIX" ]; then
  MATCH_CMD="${FIRST_CMD:${#ENV_PREFIX}}"
  CMD_BODY="${CMD:${#ENV_PREFIX}}"
else
  MATCH_CMD="$FIRST_CMD"
  CMD_BODY="$CMD"
fi

REWRITTEN=""

# --- Git commands ---
if echo "$MATCH_CMD" | grep -qE '^git[[:space:]]'; then
  # Skip: git -C <path> — RTK doesn't support git's global -C flag
  if echo "$MATCH_CMD" | grep -qE '^git[[:space:]]+-C[[:space:]]'; then
    exit 0
  fi
  GIT_SUBCMD=$(echo "$MATCH_CMD" | sed -E \
    -e 's/^git[[:space:]]+//' \
    -e 's/(-c)[[:space:]]+[^[:space:]]+[[:space:]]*//g' \
    -e 's/--[a-z-]+=[^[:space:]]+[[:space:]]*//g' \
    -e 's/--(no-pager|no-optional-locks|bare|literal-pathspecs)[[:space:]]*//g' \
    -e 's/^[[:space:]]+//')
  case "$GIT_SUBCMD" in
    status|status\ *|diff|diff\ *|log|log\ *|add|add\ *|commit|commit\ *|push|push\ *|pull|pull\ *|branch|branch\ *|fetch|fetch\ *|stash|stash\ *|show|show\ *|remote|remote\ *|checkout|checkout\ *|worktree|worktree\ *|merge|merge\ *|reset|reset\ *|tag|tag\ *|rebase|rebase\ *|cherry-pick|cherry-pick\ *)
      REWRITTEN="${ENV_PREFIX}rtk $CMD_BODY"
      ;;
  esac

# --- GitHub CLI (added: api, release, repo) ---
elif echo "$MATCH_CMD" | grep -qE '^gh[[:space:]]+(pr|issue|run|api|release|repo)([[:space:]]|$)'; then
  # Skip when piped to JSON parsers (rtk rewrites JSON → parse failure)
  if echo "$CMD" | grep -qE '\|[[:space:]]*(python3|python|jq|node|ruby)([[:space:]]|$)'; then
    exit 0
  fi
  # Skip when using --jq (structured JSON output expected, RTK would mangle it)
  if echo "$CMD" | grep -qE -- '--jq[[:space:]]'; then
    exit 0
  fi
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^gh /rtk gh /')"

# --- Cargo ---
elif echo "$MATCH_CMD" | grep -qE '^cargo[[:space:]]'; then
  CARGO_SUBCMD=$(echo "$MATCH_CMD" | sed -E 's/^cargo[[:space:]]+(\+[^[:space:]]+[[:space:]]+)?//')
  case "$CARGO_SUBCMD" in
    test|test\ *|build|build\ *|clippy|clippy\ *|check|check\ *|install|install\ *|fmt|fmt\ *)
      REWRITTEN="${ENV_PREFIX}rtk $CMD_BODY"
      ;;
  esac

# --- File operations ---
elif echo "$MATCH_CMD" | grep -qE '^cat[[:space:]]+'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^cat /rtk read /')"
elif echo "$MATCH_CMD" | grep -qE '^(rg|grep)[[:space:]]+'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(rg|grep) /rtk grep /')"
elif echo "$MATCH_CMD" | grep -qE '^ls([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^ls/rtk ls/')"
elif echo "$MATCH_CMD" | grep -qE '^tree([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^tree/rtk tree/')"
elif echo "$MATCH_CMD" | grep -qE '^find[[:space:]]+'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^find /rtk find /')"
elif echo "$MATCH_CMD" | grep -qE '^diff[[:space:]]+'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^diff /rtk diff /')"
elif echo "$MATCH_CMD" | grep -qE '^head[[:space:]]+'; then
  # Transform: head -N file → rtk read file --max-lines N
  # Also handle: head --lines=N file
  if echo "$MATCH_CMD" | grep -qE '^head[[:space:]]+-[0-9]+[[:space:]]+'; then
    LINES=$(echo "$MATCH_CMD" | sed -E 's/^head +-([0-9]+) +.+$/\1/')
    FILE=$(echo "$MATCH_CMD" | sed -E 's/^head +-[0-9]+ +(.+)$/\1/')
    REWRITTEN="${ENV_PREFIX}rtk read $FILE --max-lines $LINES"
  elif echo "$MATCH_CMD" | grep -qE '^head[[:space:]]+--lines=[0-9]+[[:space:]]+'; then
    LINES=$(echo "$MATCH_CMD" | sed -E 's/^head +--lines=([0-9]+) +.+$/\1/')
    FILE=$(echo "$MATCH_CMD" | sed -E 's/^head +--lines=[0-9]+ +(.+)$/\1/')
    REWRITTEN="${ENV_PREFIX}rtk read $FILE --max-lines $LINES"
  fi

# --- JS/TS tooling (added: npm run, npm test, vue-tsc) ---
elif echo "$MATCH_CMD" | grep -qE '^(pnpm[[:space:]]+)?(npx[[:space:]]+)?vitest([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(pnpm )?(npx )?vitest( run)?/rtk vitest run/')"
elif echo "$MATCH_CMD" | grep -qE '^pnpm[[:space:]]+test([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pnpm test/rtk vitest run/')"
elif echo "$MATCH_CMD" | grep -qE '^npm[[:space:]]+test([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^npm test/rtk npm test/')"
elif echo "$MATCH_CMD" | grep -qE '^npm[[:space:]]+run[[:space:]]+'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^npm run /rtk npm /')"
elif echo "$MATCH_CMD" | grep -qE '^(npx[[:space:]]+)?vue-tsc([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(npx )?vue-tsc/rtk tsc/')"
elif echo "$MATCH_CMD" | grep -qE '^pnpm[[:space:]]+tsc([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pnpm tsc/rtk tsc/')"
elif echo "$MATCH_CMD" | grep -qE '^(npx[[:space:]]+)?tsc([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(npx )?tsc/rtk tsc/')"
elif echo "$MATCH_CMD" | grep -qE '^pnpm[[:space:]]+lint([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pnpm lint/rtk lint/')"
elif echo "$MATCH_CMD" | grep -qE '^(npx[[:space:]]+)?eslint([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(npx )?eslint/rtk lint/')"
elif echo "$MATCH_CMD" | grep -qE '^(npx[[:space:]]+)?prettier([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(npx )?prettier/rtk prettier/')"
elif echo "$MATCH_CMD" | grep -qE '^(npx[[:space:]]+)?playwright([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(npx )?playwright/rtk playwright/')"
elif echo "$MATCH_CMD" | grep -qE '^pnpm[[:space:]]+playwright([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pnpm playwright/rtk playwright/')"
elif echo "$MATCH_CMD" | grep -qE '^(npx[[:space:]]+)?prisma([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(npx )?prisma/rtk prisma/')"

# --- Containers (docker compose, docker run/build, kubectl) ---
# Skip: docker exec — RTK intercepts the command instead of passing to container
elif echo "$MATCH_CMD" | grep -qE '^docker[[:space:]]+exec([[:space:]]|$)'; then
  exit 0
elif echo "$MATCH_CMD" | grep -qE '^docker[[:space:]]'; then
  if echo "$MATCH_CMD" | grep -qE '^docker[[:space:]]+compose([[:space:]]|$)'; then
    REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^docker /rtk docker /')"
  elif echo "$MATCH_CMD" | grep -qE '^docker[[:space:]]+inspect([[:space:]]|$)'; then
    # docker inspect: RTK doesn't support it
    exit 0
  elif echo "$MATCH_CMD" | grep -qE 'docker[[:space:]]+logs[[:space:]]' && echo "$MATCH_CMD" | grep -qE '(--tail|--since|--follow|--until|-f |-n )'; then
    # docker logs with unsupported flags
    exit 0
  elif echo "$MATCH_CMD" | grep -qE 'docker[[:space:]]+ps[[:space:]]' && echo "$MATCH_CMD" | grep -qE '(--format|--filter|-f )'; then
    # docker ps with unsupported flags
    exit 0
  else
    DOCKER_SUBCMD=$(echo "$MATCH_CMD" | sed -E \
      -e 's/^docker[[:space:]]+//' \
      -e 's/(-H|--context|--config)[[:space:]]+[^[:space:]]+[[:space:]]*//g' \
      -e 's/--[a-z-]+=[^[:space:]]+[[:space:]]*//g' \
      -e 's/^[[:space:]]+//')
    case "$DOCKER_SUBCMD" in
      ps|ps\ *|images|images\ *|logs|logs\ *|run|run\ *|build|build\ *)
        REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^docker /rtk docker /')"
        ;;
    esac
  fi
elif echo "$MATCH_CMD" | grep -qE '^kubectl[[:space:]]'; then
  KUBE_SUBCMD=$(echo "$MATCH_CMD" | sed -E \
    -e 's/^kubectl[[:space:]]+//' \
    -e 's/(--context|--kubeconfig|--namespace|-n)[[:space:]]+[^[:space:]]+[[:space:]]*//g' \
    -e 's/--[a-z-]+=[^[:space:]]+[[:space:]]*//g' \
    -e 's/^[[:space:]]+//')
  case "$KUBE_SUBCMD" in
    get|get\ *|logs|logs\ *|describe|describe\ *|apply|apply\ *)
      REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^kubectl /rtk kubectl /')"
      ;;
  esac

# --- Network ---
# Skip curl when piped to JSON parsers (rtk rewrites JSON values → parse failure)
elif echo "$MATCH_CMD" | grep -qE '^curl[[:space:]]+'; then
  if echo "$CMD" | grep -qE '\|[[:space:]]*(python3|python|jq|node|ruby)([[:space:]]|$)'; then
    exit 0
  fi
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^curl /rtk curl /')"
elif echo "$MATCH_CMD" | grep -qE '^wget[[:space:]]+'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^wget /rtk wget /')"

# --- pnpm package management ---
elif echo "$MATCH_CMD" | grep -qE '^pnpm[[:space:]]+(list|ls|outdated)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pnpm /rtk pnpm /')"

# --- Python tooling ---
elif echo "$MATCH_CMD" | grep -qE '^pytest([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pytest/rtk pytest/')"
elif echo "$MATCH_CMD" | grep -qE '^python[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^python -m pytest/rtk pytest/')"
# uv run <tool> → strip uv run, apply rtk to inner command
elif echo "$MATCH_CMD" | grep -qE '^uv[[:space:]]+run[[:space:]]+pytest([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^uv run pytest/rtk pytest/')"
elif echo "$MATCH_CMD" | grep -qE '^uv[[:space:]]+run[[:space:]]+ruff[[:space:]]+(check|format)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^uv run ruff /rtk ruff /')"
elif echo "$MATCH_CMD" | grep -qE '^uv[[:space:]]+run[[:space:]]+mypy([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^uv run mypy/rtk err mypy/')"
elif echo "$MATCH_CMD" | grep -qE '^ruff[[:space:]]+(check|format)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^ruff /rtk ruff /')"
elif echo "$MATCH_CMD" | grep -qE '^pip[[:space:]]+(list|outdated|install|show)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^pip /rtk pip /')"
elif echo "$MATCH_CMD" | grep -qE '^uv[[:space:]]+pip[[:space:]]+(list|outdated|install|show)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^uv pip /rtk pip /')"

# --- tmux (proxy for tracking, skip interactive) ---
elif echo "$MATCH_CMD" | grep -qE '^(command[[:space:]]+)?tmux[[:space:]]'; then
  # Skip interactive commands (attach, select-*, choose-*)
  if echo "$MATCH_CMD" | grep -qE '(attach|select-|choose-)'; then
    exit 0
  fi
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(command )?tmux /rtk proxy tmux /')"

# --- Go tooling ---
elif echo "$MATCH_CMD" | grep -qE '^go[[:space:]]+test([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^go test/rtk go test/')"
elif echo "$MATCH_CMD" | grep -qE '^go[[:space:]]+build([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^go build/rtk go build/')"
elif echo "$MATCH_CMD" | grep -qE '^go[[:space:]]+vet([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^go vet/rtk go vet/')"
elif echo "$MATCH_CMD" | grep -qE '^golangci-lint([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^golangci-lint/rtk golangci-lint/')"

# --- Ruby tooling (proxy: no native RTK support) ---
elif echo "$MATCH_CMD" | grep -qE '^bundle[[:space:]]+exec[[:space:]]+(rspec|rails|rake|rubocop)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^bundle exec /rtk proxy bundle exec /')"
elif echo "$MATCH_CMD" | grep -qE '^(rspec|rubocop)([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed -E 's/^(rspec|rubocop)/rtk proxy \1/')"
elif echo "$MATCH_CMD" | grep -qE '^rails[[:space:]]+(test|routes|console)([[:space:]]|$)'; then
  # skip: rails console is interactive
  if echo "$MATCH_CMD" | grep -qE '^rails[[:space:]]+console([[:space:]]|$)'; then
    exit 0
  fi
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^rails /rtk proxy rails /')"
elif echo "$MATCH_CMD" | grep -qE '^rake([[:space:]]|$)'; then
  REWRITTEN="${ENV_PREFIX}$(echo "$CMD_BODY" | sed 's/^rake/rtk proxy rake/')"
fi

# If no rewrite needed, approve as-is
if [ -z "$REWRITTEN" ]; then
  exit 0
fi

# Build the updated tool_input with all original fields preserved, only command changed
ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

# Output the rewrite instruction
jq -n \
  --argjson updated "$UPDATED_INPUT" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "RTK auto-rewrite",
      "updatedInput": $updated
    }
  }'
