#!/bin/bash
{
# Toqn Hook v4 (Claude Code + Cursor + Copilot)
# Usage: bash hook.sh <source>
# Sources: claude-code, cursor, copilot
#
# Env vars:
#   TOQN_API_KEY       - required, get from toqn.dev/settings
#   TOQN_URL           - optional, defaults to https://toqn.dev
#   TOQN_DEBUG         - set to 1 to log raw input, parsed stats, payload, and server response to /tmp/toqn-debug/
#   TOQN_AUTO_UPDATE   - set to 1 to enable self-updating when server signals new version

TOQN_HOOK_VERSION="6"

# --- Preamble ---
if [ -z "$TOQN_API_KEY" ]; then
  for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$f" ] || continue
    TOQN_API_KEY=$(sed -n 's/.*TOQN_API_KEY="\([^"]*\)".*/\1/p' "$f" 2>/dev/null | tail -1)
    [ -n "$TOQN_API_KEY" ] && break
  done
fi
[ -z "$TOQN_API_KEY" ] && exit 0

TOQN_URL="${TOQN_URL:-https://toqn.dev}"
SOURCE="$1"
[ -z "$SOURCE" ] && echo "usage: hook.sh <source>" >&2 && exit 1

INPUT=$(cat)

DEBUG="${TOQN_DEBUG:-0}"
DEBUG_DIR="/tmp/toqn-debug"
if [ "$DEBUG" = "1" ]; then
  mkdir -p "$DEBUG_DIR"
  LOG="$DEBUG_DIR/$(date +%Y%m%d-%H%M%S).log"
  debug_log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
  debug_json() { echo "[$(date +%H:%M:%S)] $1:" >> "$LOG"; echo "$2" >> "$LOG"; }
else
  debug_log() { :; }
  debug_json() { :; }
fi
debug_json "stdin" "$INPUT"
debug_log "source=$SOURCE"

# --- Extractors ---
extract_claude_code() {
  TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

  PAYLOAD=$(jq -s '
    def categorize_bash:
      [
        if test("(^|&& |; )git commit") then "git_commit" else empty end,
        if test("(^|&& |; )git push") then "git_push" else empty end,
        if test("(^|&& |; )git (pull|fetch|merge|rebase)") then "git_sync" else empty end,
        if test("(^|&& |; )git (checkout|branch|switch)") then "git_branch" else empty end,
        if test("(^|&& |; )git (diff|log|status|show|blame)") then "git_read" else empty end,
        if test("(^|&& |; )git ") then (if [test("(^|&& |; )git (commit|push|pull|fetch|merge|rebase|checkout|branch|switch|diff|log|status|show|blame)")] | any then empty else "git_other" end) else empty end,
        if test("(^|&& |; )gh pr") then "gh_pr" else empty end,
        if test("(^|&& |; )gh issue") then "gh_issue" else empty end,
        if test("(^|&& |; )gh ") then (if [test("(^|&& |; )gh (pr|issue)")] | any then empty else "gh_other" end) else empty end,
        if test("(^|&& |; )(npm |yarn |pnpm |bun (install|add|remove|update))") then "package" else empty end,
        if test("(^|&& |; )(npx |bunx )") then "runner" else empty end,
        if test("(vitest|jest|pytest|mocha|bun run test)") then "test" else empty end,
        if test("(eslint|prettier|tsc |biome |lint)") then "lint" else empty end,
        if test("(^|&& |; )(make|cmake|cargo build|go build|webpack|vite build)") then "build" else empty end,
        if test("(^|&& |; )(grep|rg |ag |find )") then "search" else empty end,
        if test("(^|&& |; )(node |python3? |ruby |tsx |ts-node)") then "script" else empty end,
        if test("(^|&& |; )curl ") then "http" else empty end,
        if test("(^|&& |; )docker ") then "docker" else empty end,
        if test("(^|&& |; )(kill |ps |lsof |top )") then "process" else empty end,
        if test("(^|&& |; )(export |source |env |which )") then "env" else empty end,
        if test("(^|&& |; )(cd |ls |mkdir |rm |cp |mv |chmod |cat |head |tail |wc |sort |uniq )") then "shell" else empty end,
        if test("(^|&& |; )(sed |awk |jq |xargs )") then "transform" else empty end
      ] | if length == 0 then ["other"] else . end;
    def basename_path: split("/") | last;

    # Extract only the latest completion.
    # The stop_hook_summary for the CURRENT turn has NOT been written yet
    # (it is appended after the hook fires), so all existing markers are
    # from previous turns.  We want everything after the last marker.
    [to_entries[] | select(.value.subtype == "stop_hook_summary") | .key] as $stops |
    (if ($stops | length) >= 1 then .[$stops[-1] + 1 :]
     else .
     end) as $slice |

    {
      assistants: [$slice[] | select(.type == "assistant")],
      tool_uses: [$slice[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")],
      tool_errors: [$slice[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)]
    } |
    {
      model: (.assistants | map(.message.model // empty) | last // "unknown"),
      turns: [.assistants[] | {
        input: (.message.usage.input_tokens // 0),
        output: (.message.usage.output_tokens // 0),
        cache_create: (.message.usage.cache_creation_input_tokens // 0),
        cache_read: (.message.usage.cache_read_input_tokens // 0)
      }],
      tools: (.tool_uses | map(.name) | group_by(.) | map({key: .[0], value: length}) | from_entries),
      lines_added: ([.tool_uses[] | select(.name == "Edit") | (.input.new_string // "" | split("\n") | length)] + [.tool_uses[] | select(.name == "Write") | (.input.content // "" | split("\n") | length)] | add // 0),
      lines_removed: ([.tool_uses[] | select(.name == "Edit") | (.input.old_string // "" | split("\n") | length)] | add // 0),
      bash_categories: ([.tool_uses[] | select(.name == "Bash") | (.input.command // "" | categorize_bash)[]] | group_by(.) | map({key: .[0], value: length}) | from_entries),
      git_commits: ([.tool_uses[] | select(.name == "Bash" and (.input.command // "" | test("(^|&& |; )git commit")))] | length),
      git_pushes: ([.tool_uses[] | select(.name == "Bash" and (.input.command // "" | test("(^|&& |; )git push")))] | length),
      prs_created: ([.tool_uses[] | select(.name == "Bash" and (.input.command // "" | test("(^|&& |; )gh pr create")))] | length),
      subagents: ([.tool_uses[] | select(.name == "Agent") | (.input.subagent_type // .input.name // "general")] | group_by(.) | map({key: .[0], value: length}) | from_entries),
      skills: ([.tool_uses[] | select(.name == "Skill") | (.input.skill // "unknown")] | group_by(.) | map({key: .[0], value: length}) | from_entries),
      tool_errors: (.tool_errors | length),
      files_changed: ([.tool_uses[] | select(.name == "Edit" or .name == "Write") | (.input.file_path // "" | split(".") | last)] | map(select(. != "")) | group_by(.) | map({key: .[0], value: length}) | from_entries),
      files_read: ([.tool_uses[] | select(.name == "Read") | (.input.file_path // "" | split(".") | last)] | map(select(. != "")) | group_by(.) | map({key: .[0], value: length}) | from_entries)
    }
  ' "$TRANSCRIPT" 2>/dev/null) || exit 0

  PAYLOAD=$(echo "$PAYLOAD" | jq \
    --arg sid "$SESSION_ID" \
    --arg proj "$PROJECT" \
    '. + {session_id: $sid, project: $proj}')

  debug_json "payload" "$PAYLOAD"
  post_payload "$PAYLOAD"
}

extract_cursor() {
  MODEL=$(echo "$INPUT" | jq -r '.model // "unknown"')
  CONVERSATION_ID=$(echo "$INPUT" | jq -r '.conversation_id // empty')

  # Project: use workspace_roots (populated when Cursor opens a folder)
  CWD=$(echo "$INPUT" | jq -r '.workspace_roots[0] // empty')
  PROJECT=$(basename "$CWD" 2>/dev/null)
  [ -z "$PROJECT" ] && PROJECT="unknown"

  # Prefer envelope token data (Cursor 2.7+), fall back to transcript estimation
  ENV_INPUT=$(echo "$INPUT" | jq '.input_tokens // 0')
  ENV_OUTPUT=$(echo "$INPUT" | jq '.output_tokens // 0')
  ENV_CACHE_READ=$(echo "$INPUT" | jq '.cache_read_tokens // 0')
  ENV_CACHE_WRITE=$(echo "$INPUT" | jq '.cache_write_tokens // 0')

  if [ "$ENV_INPUT" -gt 0 ] || [ "$ENV_OUTPUT" -gt 0 ] 2>/dev/null; then
    # Use actual token data from envelope
    EST_INPUT=$ENV_INPUT
    EST_OUTPUT=$ENV_OUTPUT
    CACHE_READ=$ENV_CACHE_READ
    CACHE_WRITE=$ENV_CACHE_WRITE
    ESTIMATED="false"
  else
    # Fall back to transcript char estimation
    TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
    EST_INPUT=0
    EST_OUTPUT=0
    CACHE_READ=0
    CACHE_WRITE=0
    ESTIMATED="true"

    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      STATS=$(jq -s '
        {
          est_input: ([.[] | select(.role == "user") | .content | length] | add // 0),
          est_output: ([.[] | select(.role == "assistant") | .content | length] | add // 0)
        } |
        .est_input = ((.est_input + 3) / 4 | floor) |
        .est_output = ((.est_output + 3) / 4 | floor)
      ' "$TRANSCRIPT" 2>/dev/null)

      if [ -n "$STATS" ]; then
        EST_INPUT=$(echo "$STATS" | jq '.est_input')
        EST_OUTPUT=$(echo "$STATS" | jq '.est_output')
      fi
    fi
  fi

  # Count turns from transcript if available
  TURNS=0
  TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    TURNS=$(jq -s '[.[] | select(.role == "assistant")] | length' "$TRANSCRIPT" 2>/dev/null || echo 0)
  fi

  PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg proj "$PROJECT" \
    --arg cid "$CONVERSATION_ID" \
    --argjson turns "$TURNS" \
    --argjson est_in "$EST_INPUT" \
    --argjson est_out "$EST_OUTPUT" \
    --argjson cache_read "$CACHE_READ" \
    --argjson cache_write "$CACHE_WRITE" \
    --argjson estimated "$ESTIMATED" \
    '{model:$model, project:$proj, conversation_id:$cid, num_turns:$turns, estimated_input_tokens:$est_in, estimated_output_tokens:$est_out, cache_read_tokens:$cache_read, cache_write_tokens:$cache_write, estimated:$estimated}')

  debug_json "payload" "$PAYLOAD"
  post_payload "$PAYLOAD"
}

extract_copilot() {
  TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  SESSION_ID=$(echo "$INPUT" | jq -r '.sessionId // empty')
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

  EST_INPUT=0
  EST_OUTPUT=0
  TURNS=0
  MODEL="unknown"
  TOOLS='{}'
  GIT_COMMITS=0
  GIT_PUSHES=0
  TOOL_ERRORS=0
  FILES_CHANGED='{}'

  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Track how many messages we've already counted for this session to avoid
    # inflating usage on repeated Stop events in long-lived sessions.
    # The offset file stores the message count from the previous invocation.
    OFFSET_DIR="/tmp/toqn-copilot-offsets"
    mkdir -p "$OFFSET_DIR" 2>/dev/null
    OFFSET_KEY=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
    [ -z "$OFFSET_KEY" ] && OFFSET_KEY=$(echo "$TRANSCRIPT" | md5sum 2>/dev/null | cut -c1-16 || echo "default")
    OFFSET_FILE="$OFFSET_DIR/$OFFSET_KEY"
    PREV_OFFSET=0
    [ -f "$OFFSET_FILE" ] && PREV_OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

    # Copilot VS Code transcript is a JSON file (not JSONL).
    # Slice to only new messages since last Stop, then extract stats.
    STATS=$(jq --argjson offset "$PREV_OFFSET" '
      def char_to_tokens: ((. + 3) / 4 | floor);
      def content_len: if type == "string" then length elif type == "array" then ([.[] | .text // "" | length] | add // 0) else 0 end;
      (if type == "array" then . else (.messages // .turns // []) end) as $all |
      ($all | length) as $total |
      $all[$offset:] as $msgs |
      {
        total_count: $total,
        model: ([$all[] | .model // empty] | last // "unknown"),
        num_turns: ([$msgs[] | select(.role == "assistant")] | length),
        est_input: ([$msgs[] | select(.role == "user") | (.content | content_len)] | add // 0 | char_to_tokens),
        est_output: ([$msgs[] | select(.role == "assistant") | (.content | content_len)] | add // 0 | char_to_tokens),
        tools: ([$msgs[] | select(.role == "assistant") | .tool_calls[]? | .function.name // .type // empty] | group_by(.) | map({key: .[0], value: length}) | from_entries),
        git_commits: ([$msgs[] | select(.role == "assistant") | .tool_calls[]? | select((.function.name // "") == "runTerminalCommand") | .function.arguments // "" | select(test("git commit"))] | length),
        git_pushes: ([$msgs[] | select(.role == "assistant") | .tool_calls[]? | select((.function.name // "") == "runTerminalCommand") | .function.arguments // "" | select(test("git push"))] | length),
        tool_errors: ([$msgs[] | select(.role == "tool" and (.content // "" | test("error|Error|ERROR")))] | length),
        files_changed: ([$msgs[] | select(.role == "assistant") | .tool_calls[]? | select((.function.name // "") | test("editFiles|createFile")) | ((.function.arguments | fromjson? | .file // .path // "") // "") | split(".") | last] | map(select(. != "")) | group_by(.) | map({key: .[0], value: length}) | from_entries)
      }
    ' "$TRANSCRIPT" 2>/dev/null)

    if [ -n "$STATS" ]; then
      # Save current total message count for next invocation
      TOTAL_COUNT=$(echo "$STATS" | jq '.total_count')
      echo "$TOTAL_COUNT" > "$OFFSET_FILE" 2>/dev/null

      MODEL=$(echo "$STATS" | jq -r '.model')
      TURNS=$(echo "$STATS" | jq '.num_turns')
      EST_INPUT=$(echo "$STATS" | jq '.est_input')
      EST_OUTPUT=$(echo "$STATS" | jq '.est_output')
      TOOLS=$(echo "$STATS" | jq -c '.tools')
      GIT_COMMITS=$(echo "$STATS" | jq '.git_commits')
      GIT_PUSHES=$(echo "$STATS" | jq '.git_pushes')
      TOOL_ERRORS=$(echo "$STATS" | jq '.tool_errors')
      FILES_CHANGED=$(echo "$STATS" | jq -c '.files_changed')
    fi
  fi

  # If no transcript or parsing failed, still send what we have
  PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg proj "$PROJECT" \
    --arg sid "$SESSION_ID" \
    --argjson turns "$TURNS" \
    --argjson est_in "$EST_INPUT" \
    --argjson est_out "$EST_OUTPUT" \
    --argjson tools "$TOOLS" \
    --argjson git_commits "$GIT_COMMITS" \
    --argjson git_pushes "$GIT_PUSHES" \
    --argjson tool_errors "$TOOL_ERRORS" \
    --argjson files_changed "$FILES_CHANGED" \
    '{model:$model, project:$proj, session_id:$sid, num_turns:$turns, estimated_input_tokens:$est_in, estimated_output_tokens:$est_out, tools:$tools, git_commits:$git_commits, git_pushes:$git_pushes, tool_errors:$tool_errors, files_changed:$files_changed}')

  debug_json "payload" "$PAYLOAD"
  post_payload "$PAYLOAD"
}

# --- Common POST ---
post_payload() {
  local PAYLOAD="$1"

  if [ "$DEBUG" = "1" ]; then
    RESPONSE=$(curl -s --max-time 10 -D - -o /tmp/toqn-body.$$ \
      -X POST "$TOQN_URL/api/ingest/v2" \
      -H "Authorization: Bearer $TOQN_API_KEY" \
      -H "X-Toqn-Source: $SOURCE" \
      -H "X-Toqn-Hook: $TOQN_HOOK_VERSION" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD")
    BODY=$(cat /tmp/toqn-body.$$ 2>/dev/null); rm -f /tmp/toqn-body.$$
    debug_json "response headers" "$RESPONSE"
    debug_json "response body" "$BODY"
    debug_log "debug log: $LOG"
    echo "toqn: debug log at $LOG" >&2
    HEADERS="$RESPONSE"
  else
    HEADERS=$(curl -s --max-time 10 -D - -o /dev/null \
      -X POST "$TOQN_URL/api/ingest/v2" \
      -H "Authorization: Bearer $TOQN_API_KEY" \
      -H "X-Toqn-Source: $SOURCE" \
      -H "X-Toqn-Hook: $TOQN_HOOK_VERSION" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD")
  fi

  # Self-update check
  UPDATE_URL=$(echo "$HEADERS" | grep -i "x-toqn-update" | tr -d '\r' | sed 's/.*: //')
  if [ -n "$UPDATE_URL" ] && [ "$TOQN_AUTO_UPDATE" = "1" ]; then
    TMP="$HOME/.toqn/hook.sh.tmp"
    if curl -fsSL --max-time 10 "$UPDATE_URL" -o "$TMP" 2>/dev/null; then
      if bash -n "$TMP" 2>/dev/null; then
        mv "$TMP" "$HOME/.toqn/hook.sh"
        debug_log "self-updated from $UPDATE_URL"
      else
        rm -f "$TMP"
        debug_log "self-update failed syntax check"
      fi
    fi
  fi
}

extract_codex() {
  TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
  [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

  PAYLOAD=$(jq -s '
    def categorize_bash:
      [
        if test("(^|&& |; )git commit") then "git_commit" else empty end,
        if test("(^|&& |; )git push") then "git_push" else empty end,
        if test("(^|&& |; )git (pull|fetch|merge|rebase)") then "git_sync" else empty end,
        if test("(^|&& |; )git (checkout|branch|switch)") then "git_branch" else empty end,
        if test("(^|&& |; )git (diff|log|status|show|blame)") then "git_read" else empty end,
        if test("(^|&& |; )git ") then (if [test("(^|&& |; )git (commit|push|pull|fetch|merge|rebase|checkout|branch|switch|diff|log|status|show|blame)")] | any then empty else "git_other" end) else empty end,
        if test("(^|&& |; )gh pr") then "gh_pr" else empty end,
        if test("(^|&& |; )gh issue") then "gh_issue" else empty end,
        if test("(^|&& |; )(npm |yarn |pnpm |bun (install|add|remove|update))") then "package" else empty end,
        if test("(^|&& |; )(npx |bunx )") then "runner" else empty end,
        if test("(vitest|jest|pytest|mocha|bun run test)") then "test" else empty end,
        if test("(eslint|prettier|tsc |biome |lint)") then "lint" else empty end,
        if test("(^|&& |; )(make|cmake|cargo build|go build|webpack|vite build)") then "build" else empty end,
        if test("(^|&& |; )(grep|rg |ag |find )") then "search" else empty end,
        if test("(^|&& |; )(node |python3? |ruby |tsx |ts-node)") then "script" else empty end,
        if test("(^|&& |; )curl ") then "http" else empty end,
        if test("(^|&& |; )docker ") then "docker" else empty end,
        if test("(^|&& |; )(kill |ps |lsof |top )") then "process" else empty end,
        if test("(^|&& |; )(export |source |env |which )") then "env" else empty end,
        if test("(^|&& |; )(cd |ls |mkdir |rm |cp |mv |chmod |cat |head |tail |wc |sort |uniq )") then "shell" else empty end,
        if test("(^|&& |; )(sed |awk |jq |xargs )") then "transform" else empty end
      ] | if length == 0 then ["other"] else . end;

    # Slice to current turn only: everything after the second-to-last
    # task_complete (analogous to Claude Codes stop_hook_summary boundary).
    # Unlike Claude Code, the CURRENT turns task_complete IS already written
    # when the Stop hook fires, so we need entries between the penultimate
    # task_complete and the last one.
    [to_entries[] | select(.value.type == "event_msg" and .value.payload.type == "task_complete") | .key] as $boundaries |
    (if ($boundaries | length) >= 2 then .[$boundaries[-2] + 1:]
     else .
     end) as $slice |

    # Use last_token_usage (per-turn delta), NOT total_token_usage (cumulative)
    ([ $slice[] | select(.type == "event_msg" and .payload.type == "token_count" and .payload.info != null) | .payload.info.last_token_usage ] | last // {}) as $tokens |

    # Extract model from turn_context in current slice
    ([ $slice[] | select(.type == "turn_context") | .payload.model ] | last // "unknown") as $model |

    # Current turn = 1 (each Stop fires once per turn)
    1 as $num_turns |

    # Extract tool calls from current turn (both function_call and custom_tool_call)
    [ $slice[] | select(.type == "response_item" and (.payload.type == "function_call" or .payload.type == "custom_tool_call")) ] as $tool_calls |

    # Parse exec_command arguments to get shell commands
    [ $tool_calls[] | select(.payload.name == "exec_command") | (.payload.arguments | fromjson? // {}).cmd // empty ] as $cmds |

    # Extract apply_patch inputs for line/file counting
    [ $tool_calls[] | select(.payload.name == "apply_patch") | .payload.input // "" ] as $patches |

    # Count lines added/removed from apply_patch diffs (+ and - prefixed lines)
    ([ $patches[] | split("\n")[] | select(startswith("+")) ] | length) as $lines_added |
    ([ $patches[] | split("\n")[] | select(startswith("-")) ] | length) as $lines_removed |

    # Extract file extensions from apply_patch headers (*** Add/Update/Delete File: path)
    ([ $patches[] | split("\n")[] | select(test("^\\*\\*\\* (Add|Update|Delete) File:")) | sub("^\\*\\*\\* (Add|Update|Delete) File:\\s*"; "") | split("/") | last | split(".") | if length > 1 then last else empty end ] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $files_changed |

    # Extract file extensions from read commands (sed/cat/head/tail/less on files)
    ([ $cmds[] | capture("(?:sed -n .+ |cat |head |tail |less |more )(?<path>[^ |>]+)$") | .path | split("/") | last | split(".") | if length > 1 then last else empty end ] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $files_read |

    # Count tool errors from custom_tool_call_output with error status
    ([ $slice[] | select(.type == "response_item" and .payload.type == "custom_tool_call_output" and .payload.status == "incomplete") ] | length) as $tool_errors |

    {
      model: $model,
      input_tokens: ($tokens.input_tokens // 0),
      output_tokens: ($tokens.output_tokens // 0),
      cached_input_tokens: ($tokens.cached_input_tokens // 0),
      reasoning_output_tokens: ($tokens.reasoning_output_tokens // 0),
      num_turns: $num_turns,
      tools: ($tool_calls | map(.payload.name) | group_by(.) | map({key: .[0], value: length}) | from_entries),
      lines_added: $lines_added,
      lines_removed: $lines_removed,
      bash_categories: ([ $cmds[] | categorize_bash[] ] | group_by(.) | map({key: .[0], value: length}) | from_entries),
      git_commits: ([ $cmds[] | select(test("(^|&& |; )git commit")) ] | length),
      git_pushes: ([ $cmds[] | select(test("(^|&& |; )git push")) ] | length),
      prs_created: ([ $cmds[] | select(test("(^|&& |; )gh pr create")) ] | length),
      tool_errors: $tool_errors,
      files_changed: $files_changed,
      files_read: $files_read
    }
  ' "$TRANSCRIPT" 2>/dev/null) || exit 0

  PAYLOAD=$(echo "$PAYLOAD" | jq \
    --arg sid "$SESSION_ID" \
    --arg proj "$PROJECT" \
    '. + {session_id: $sid, project: $proj}')

  debug_json "payload" "$PAYLOAD"
  post_payload "$PAYLOAD"
}

# --- Dispatch ---
case "$SOURCE" in
  claude-code) extract_claude_code ;;
  codex)       extract_codex ;;
  copilot)     extract_copilot ;;
  cursor)      extract_cursor ;;
  *)           echo "toqn: unknown source '$SOURCE'" >&2; exit 0 ;;
esac

exit 0
}
