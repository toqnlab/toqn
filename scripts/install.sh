#!/bin/bash
set -e

# --- Timeline output helpers ---
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

tl_done()  { printf "  ${GREEN}●${RESET} %s\n" "$1"; }
tl_skip()  { printf "  ${DIM}○ %s${RESET}\n" "$1"; }
tl_active(){ printf "  ${YELLOW}○${RESET} %s\n" "$1"; }
tl_line()  { printf "  ${GREEN}│${RESET}\n"; }
tl_dimline() { printf "  ${DIM}│${RESET}\n"; }
tl_box() {
  local lines=("$@")
  local max=0
  for line in "${lines[@]}"; do
    local stripped
    stripped=$(printf "%b" "$line" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#stripped}
    [ "$len" -gt "$max" ] && max=$len
  done
  [ "$max" -lt 40 ] && max=40
  local w=$((max + 4))
  local border
  border=$(printf '─%.0s' $(seq 1 "$w"))

  printf "  ${DIM}┌%s┐${RESET}\n" "$border"
  printf "  ${DIM}│${RESET}  %*s  ${DIM}│${RESET}\n" "-$max" ""
  for line in "${lines[@]}"; do
    local stripped
    stripped=$(printf "%b" "$line" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$((max - ${#stripped}))
    printf "  ${DIM}│${RESET}  %b%*s  ${DIM}│${RESET}\n" "$line" "$pad" ""
  done
  printf "  ${DIM}│${RESET}  %*s  ${DIM}│${RESET}\n" "-$max" ""
  printf "  ${DIM}└%s┘${RESET}\n" "$border"
}

API_KEY="${1:-}"

if [ -z "$API_KEY" ]; then
  # Try device authorization flow
  TOQN_BASE="${TOQN_URL:-https://toqn.dev}"
  DEVICE_RESP=$(curl -sf --connect-timeout 3 -X POST "${TOQN_BASE}/api/auth/device" 2>/dev/null || echo "")

  if [ -n "$DEVICE_RESP" ] && command -v python3 >/dev/null 2>&1; then
    DEVICE_CODE=$(echo "$DEVICE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_code'])" 2>/dev/null || echo "")
    USER_CODE=$(echo "$DEVICE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_code'])" 2>/dev/null || echo "")
    VERIFY_URL=$(echo "$DEVICE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['verification_url'])" 2>/dev/null || echo "")
    POLL_INTERVAL=$(echo "$DEVICE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('interval',5))" 2>/dev/null || echo "5")

    if [ -n "$DEVICE_CODE" ] && [ -n "$VERIFY_URL" ]; then
      echo ""
      printf "  \033[1mtoqn\033[0m — hook installer\n"
      echo ""
      printf "  \033[2mCode: %s\033[0m\n" "$USER_CODE"
      printf "  \033[2mURL: %s\033[0m\n" "$VERIFY_URL"
      echo ""
      printf "  Press Enter to open the browser..." >&2
      read -r < /dev/tty 2>/dev/null || true

      # Try to open browser
      if command -v open >/dev/null 2>&1; then
        open "$VERIFY_URL" 2>/dev/null
      elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$VERIFY_URL" 2>/dev/null
      else
        printf "  \033[2mCould not open browser automatically.\033[0m\n"
      fi

      printf "  \033[2mWaiting for authorization...\033[0m "
      ATTEMPTS=0
      MAX_ATTEMPTS=120
      while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
        sleep "$POLL_INTERVAL"
        TOKEN_RESP=$(curl -sf -X POST "${TOQN_BASE}/api/auth/device/token" \
          -H "Content-Type: application/json" \
          -d "{\"device_code\":\"$DEVICE_CODE\"}" 2>/dev/null || echo "")

        if [ -n "$TOKEN_RESP" ]; then
          STATUS=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
          if [ "$STATUS" = "authorized" ]; then
            API_KEY=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['api_key'])" 2>/dev/null || echo "")
            printf "\033[32m✓\033[0m\n"
            break
          elif [ "$STATUS" = "expired" ]; then
            printf "\033[31m✗ expired\033[0m\n"
            break
          fi
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
      done
    fi
  fi

  # Fallback: interactive TTY prompt
  if [ -z "$API_KEY" ]; then
    if [ -t 0 ] || [ -t 2 ]; then
      echo ""
      printf "  \033[1mtoqn\033[0m — LLM token tracker\n"
      printf "  \033[2mGet your API key at: https://toqn.dev/settings\033[0m\n"
      echo ""
      printf "  Enter your API key: " >&2
      read -r API_KEY < /dev/tty
      echo ""
    fi
    if [ -z "$API_KEY" ]; then
      printf "\033[31m  Error: API key is required.\033[0m\n" >&2
      printf "\033[2m  Usage: curl -fsSL toqn.dev/install | bash -s -- YOUR_API_KEY\033[0m\n" >&2
      exit 1
    fi
  fi
fi

echo ""
printf "  ${BOLD}toqn${RESET} ${DIM}installer${RESET}\n"
echo ""

# 0. Migrate from old tokenprofile installation
OLD_DIR="$HOME/.tokenprofile"
if [ -d "$OLD_DIR" ]; then
  rm -rf "$OLD_DIR"
fi

# Migrate old env var (TOKEN_PROFILE_API_KEY → TOQN_API_KEY)
for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
  [ -f "$f" ] || continue
  if grep -q "TOKEN_PROFILE_API_KEY" "$f" 2>/dev/null; then
    sed -i.bak '/export TOKEN_PROFILE_API_KEY=/d' "$f"
    rm -f "${f}.bak"
  fi
done

# Clean old hook references from Claude Code settings
if [ -f "$HOME/.claude/settings.json" ] && grep -q "\.tokenprofile" "$HOME/.claude/settings.json" 2>/dev/null; then
  if command -v jq &>/dev/null; then
    UPDATED=$(jq '
      if .hooks.Stop then
        .hooks.Stop |= map(select(.hooks[0].command | test("\\.tokenprofile") | not))
      else . end
    ' "$HOME/.claude/settings.json")
    echo "$UPDATED" > "$HOME/.claude/settings.json"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
stops = data.get('hooks',{}).get('Stop',[])
data['hooks']['Stop'] = [s for s in stops if '.tokenprofile' not in json.dumps(s)]
with open(sys.argv[1],'w') as f: json.dump(data, f, indent=2)
" "$HOME/.claude/settings.json"
  fi
fi

# Clean old hook references from Cursor hooks
if [ -f "$HOME/.cursor/hooks.json" ] && grep -q "\.tokenprofile" "$HOME/.cursor/hooks.json" 2>/dev/null; then
  if command -v jq &>/dev/null; then
    UPDATED=$(jq '
      if .hooks.stop then
        .hooks.stop |= map(select((.command // "") + ((.args // [])[0] // "") | test("\\.tokenprofile") | not))
      else . end
    ' "$HOME/.cursor/hooks.json")
    echo "$UPDATED" > "$HOME/.cursor/hooks.json"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
stops = data.get('hooks',{}).get('stop',[])
data['hooks']['stop'] = [s for s in stops if '.tokenprofile' not in json.dumps(s)]
with open(sys.argv[1],'w') as f: json.dump(data, f, indent=2)
" "$HOME/.cursor/hooks.json"
  fi
fi

HOOK_DIR="$HOME/.toqn"
HOOK_SCRIPT="$HOOK_DIR/hook.sh"

# 1. Create hook directory
mkdir -p "$HOOK_DIR"

# 2. Download hook script
curl -fsSL "https://toqn.dev/scripts/toqn-hook.sh" -o "$HOOK_SCRIPT"
chmod +x "$HOOK_SCRIPT"

tl_done "Authenticate"
tl_line

tl_done "Download hook script"
tl_line

# 3. Add API key to shell config
SHELL_CONFIG=""
if [ -f "$HOME/.zshrc" ]; then
  SHELL_CONFIG="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
  SHELL_CONFIG="$HOME/.bashrc"
elif [ -f "$HOME/.bash_profile" ]; then
  SHELL_CONFIG="$HOME/.bash_profile"
else
  SHELL_CONFIG="$HOME/.profile"
fi

if ! grep -q "TOQN_API_KEY" "$SHELL_CONFIG" 2>/dev/null; then
  printf '\nexport TOQN_API_KEY="%s"\n' "$API_KEY" >> "$SHELL_CONFIG"
else
  sed -i.bak 's|export TOQN_API_KEY="[^"]*"|export TOQN_API_KEY="'"$API_KEY"'"|' "$SHELL_CONFIG"
  rm -f "${SHELL_CONFIG}.bak"
fi

tl_done "Save API key to $(basename "$SHELL_CONFIG")"
tl_line

CONFIGURED=""

# 4. Configure Claude Code (if installed)
if [ -d "$HOME/.claude" ]; then
  SETTINGS_FILE="$HOME/.claude/settings.json"

  # Clean up old hook location if present
  OLD_HOOK="$HOME/.claude/hooks/toqn-hook.sh"
  if [ -f "$OLD_HOOK" ]; then
    rm -f "$OLD_HOOK"
  fi

  if [ -f "$SETTINGS_FILE" ]; then
    if grep -q "bash $HOOK_SCRIPT claude-code" "$SETTINGS_FILE" 2>/dev/null; then
      tl_done "Configure Claude Code"
    elif command -v jq &>/dev/null; then
      HOOK_ENTRY='{"matcher":"","hooks":[{"type":"command","command":"bash '"$HOOK_SCRIPT"' claude-code","async":true}]}'
      UPDATED=$(jq --argjson hook "[$HOOK_ENTRY]" '
        .hooks.Stop = ((.hooks.Stop // []) + $hook | unique_by(.hooks[0].command))
      ' "$SETTINGS_FILE")
      TMP_FILE=$(mktemp "$SETTINGS_FILE.XXXXXX")
      echo "$UPDATED" > "$TMP_FILE" && mv "$TMP_FILE" "$SETTINGS_FILE"
      tl_done "Configure Claude Code"
    elif command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
hook = {'matcher':'','hooks':[{'type':'command','command':'bash '+sys.argv[2]+' claude-code','async':True}]}
stops = data.setdefault('hooks',{}).setdefault('Stop',[])
if not any(h.get('hooks',[{}])[0].get('command','').endswith('hook.sh claude-code') for h in stops):
    stops.append(hook)
with open(sys.argv[1],'w') as f: json.dump(data, f, indent=2)
" "$SETTINGS_FILE" "$HOOK_SCRIPT"
      tl_done "Configure Claude Code"
    else
      tl_skip "Configure Claude Code — no jq or python3"
    fi
  else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" << SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOOK_SCRIPT claude-code",
            "async": true
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
    tl_done "Configure Claude Code"
  fi

  CONFIGURED="${CONFIGURED}Claude Code, "
else
  tl_skip "Configure Claude Code — not found"
fi
tl_line

# 5. Configure Cursor (if installed)
if [ -d "$HOME/.cursor" ]; then
  CURSOR_HOOKS="$HOME/.cursor/hooks.json"
  NEW_HOOK='{"command":"bash '"$HOOK_SCRIPT"' cursor"}'

  if [ -f "$CURSOR_HOOKS" ] && grep -q "bash $HOOK_SCRIPT cursor" "$CURSOR_HOOKS" 2>/dev/null; then
    tl_done "Configure Cursor"
  elif [ -f "$CURSOR_HOOKS" ]; then
    if command -v jq &>/dev/null; then
      UPDATED=$(jq --argjson hook "[$NEW_HOOK]" '
        .hooks.stop = ((.hooks.stop // []) + $hook | unique_by(.command))
      ' "$CURSOR_HOOKS")
      TMP_FILE=$(mktemp "$CURSOR_HOOKS.XXXXXX")
      echo "$UPDATED" > "$TMP_FILE" && mv "$TMP_FILE" "$CURSOR_HOOKS"
      tl_done "Configure Cursor"
    elif command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
hook = {'command':'bash '+sys.argv[2]+' cursor'}
stops = data.setdefault('hooks',{}).setdefault('stop',[])
if not any('cursor' in h.get('command','') for h in stops):
    stops.append(hook)
with open(sys.argv[1],'w') as f: json.dump(data, f, indent=2)
" "$CURSOR_HOOKS" "$HOOK_SCRIPT"
      tl_done "Configure Cursor"
    else
      tl_skip "Configure Cursor — no jq or python3"
    fi
  else
    cat > "$CURSOR_HOOKS" << CURSOR_EOF
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "command": "bash $HOOK_SCRIPT cursor"
      }
    ]
  }
}
CURSOR_EOF
    tl_done "Configure Cursor"
  fi
  CONFIGURED="${CONFIGURED}Cursor, "
else
  tl_skip "Configure Cursor — not found"
fi
tl_line

# 6. Configure Codex (if installed)
if [ -d "$HOME/.codex" ]; then
  CODEX_HOOKS="$HOME/.codex/hooks.json"
  CODEX_CONFIG="$HOME/.codex/config.toml"

  # Ensure codex_hooks feature flag is enabled in config.toml
  if [ -f "$CODEX_CONFIG" ]; then
    if ! grep -q "codex_hooks" "$CODEX_CONFIG" 2>/dev/null; then
      if grep -q '^\[features\]' "$CODEX_CONFIG" 2>/dev/null; then
        sed -i.bak '/^\[features\]/a\
codex_hooks=true' "$CODEX_CONFIG"
        rm -f "${CODEX_CONFIG}.bak"
      else
        printf '\n[features]\ncodex_hooks=true\n' >> "$CODEX_CONFIG"
      fi
    fi
  else
    printf '[features]\ncodex_hooks=true\n' > "$CODEX_CONFIG"
  fi

  CODEX_HOOK_CMD="bash $HOOK_SCRIPT codex"

  if [ -f "$CODEX_HOOKS" ] && grep -q "$CODEX_HOOK_CMD" "$CODEX_HOOKS" 2>/dev/null; then
    tl_done "Configure Codex"
  elif [ -f "$CODEX_HOOKS" ]; then
    if command -v jq &>/dev/null; then
      NEW_HOOK='{"hooks":[{"type":"command","command":"'"$CODEX_HOOK_CMD"'","timeout":30}]}'
      UPDATED=$(jq --argjson hook "[$NEW_HOOK]" '
        .hooks.Stop = ((.hooks.Stop // []) + $hook | unique_by(.hooks[0].command))
      ' "$CODEX_HOOKS")
      TMP_FILE=$(mktemp "$CODEX_HOOKS.XXXXXX")
      echo "$UPDATED" > "$TMP_FILE" && mv "$TMP_FILE" "$CODEX_HOOKS"
      tl_done "Configure Codex"
    elif command -v python3 &>/dev/null; then
      python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
hook = {'hooks':[{'type':'command','command':'bash '+sys.argv[2]+' codex','timeout':30}]}
stops = data.setdefault('hooks',{}).setdefault('Stop',[])
if not any('codex' in json.dumps(h) and 'hook.sh' in json.dumps(h) for h in stops):
    stops.append(hook)
with open(sys.argv[1],'w') as f: json.dump(data, f, indent=2)
" "$CODEX_HOOKS" "$HOOK_SCRIPT"
      tl_done "Configure Codex"
    else
      tl_skip "Configure Codex — no jq or python3"
    fi
  else
    cat > "$CODEX_HOOKS" << CODEX_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOOK_SCRIPT codex",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
CODEX_EOF
    tl_done "Configure Codex"
  fi
  CONFIGURED="${CONFIGURED}Codex, "
else
  tl_skip "Configure Codex — not found"
fi
tl_line

# Ask about auto-update
if [ -t 0 ] || [ -t 2 ]; then
  printf "  ${DIM}?${RESET} auto-update hook script? [Y/n] " >&2
  read -r ANSWER < /dev/tty 2>/dev/null || ANSWER="y"
else
  ANSWER="y"
fi
case "$ANSWER" in
  [nN]*) AUTO_UPDATE=0 ;;
  *)     AUTO_UPDATE=1 ;;
esac

if ! grep -q "TOQN_AUTO_UPDATE" "$SHELL_CONFIG" 2>/dev/null; then
  printf '\nexport TOQN_AUTO_UPDATE="%s"\n' "$AUTO_UPDATE" >> "$SHELL_CONFIG"
else
  sed -i.bak 's|export TOQN_AUTO_UPDATE="[^"]*"|export TOQN_AUTO_UPDATE="'"$AUTO_UPDATE"'"|' "$SHELL_CONFIG"
  rm -f "${SHELL_CONFIG}.bak"
fi

if [ "$AUTO_UPDATE" = "1" ]; then
  tl_done "Auto-update enabled"
else
  tl_done "Auto-update disabled"
fi

echo ""
tl_box \
  "${BOLD}No code access. No conversation access. Ever.${RESET}" \
  "toqn tracks usage stats -- tokens, costs, tool" \
  "counts — never what you write or say." \
  "${DIM}Details: https://toqn.dev/privacy${RESET}"
echo ""
if [ -n "$CONFIGURED" ]; then
  CONFIGURED=$(echo "$CONFIGURED" | sed 's/, $//')
  tl_box \
    "${GREEN}${BOLD}All set!${RESET} Installed for ${BOLD}${CONFIGURED}${RESET}" \
    "${DIM}Run a completion to verify it's working.${RESET}" \
    "${DIM}https://toqn.dev${RESET}"
else
  tl_box \
    "${GREEN}${BOLD}Hook saved${RESET} ${DIM}to ~/.toqn/hook.sh${RESET}" \
    "${DIM}No supported tool found (Claude Code, Codex, Cursor).${RESET}" \
    "${DIM}Hook will activate when you install one.${RESET}" \
    "${DIM}https://toqn.dev${RESET}"
fi
echo ""
