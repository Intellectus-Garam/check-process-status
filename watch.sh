#!/usr/bin/env bash
# check-process-status: daily watcher for int2DDS long-term tmux tests.
#
# Runs locally on each test machine (cron), inspects the running tmux
# sessions, and posts a one-shot summary to Slack:
#   - liveness   : is each pub/sub process still running (not back to a shell)
#   - receiving  : does each subscriber pane print new lines within WAIT_SECONDS
#   - memory     : per-process RSS/CPU + system Mem/Swap (test processes only)
#
# Config (all env-overridable):
#   MANIFEST          path to manifest.conf      (default: <script dir>/manifest.conf)
#   ENV_FILE          path to .env               (default: <script dir>/.env)
#   WAIT_SECONDS      gap between the two pane captures (default: 60)
#   MEM_THRESHOLD_MB  per-process RSS alert threshold in MB (default: 1500)
#   SLACK_WEBHOOK_URL Slack Incoming Webhook (usually set in .env)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-$SCRIPT_DIR/manifest.conf}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
MEM_THRESHOLD_MB="${MEM_THRESHOLD_MB:-1500}"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

[ -f "$ENV_FILE" ] && . "$ENV_FILE"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# temp dir for pane snapshots; global so the EXIT trap can clean it up
WORKDIR=""

# ---------------------------------------------------------------------------
# Pure helpers (covered by test/run_tests.sh)
# ---------------------------------------------------------------------------

# True when a pane's current command is an interactive shell, i.e. the test
# binary has exited and control returned to the prompt.
is_shell_cmd() {
  case "$1" in
    bash|-bash|sh|-sh|zsh|-zsh|fish|-fish|dash|ksh|login) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the last non-empty line read from stdin.
last_nonempty_line() {
  awk 'NF{l=$0} END{print l}'
}

# Format a KB value as a human string (M below 1G, G above).
human_kb() {
  local kb="$1"
  if [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN{printf "%.1fG", k/1048576}'
  else
    awk -v k="$kb" 'BEGIN{printf "%dM", k/1024}'
  fi
}

# True when rss (KB) exceeds threshold (MB).
rss_exceeds() {
  local rss_kb="$1" thr_mb="$2"
  [ "$rss_kb" -gt $(( thr_mb * 1024 )) ]
}

# Read stdin and emit a JSON-quoted string (including surrounding quotes).
json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
    return
  fi
  local s
  s="$(cat)"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

post_slack() {
  local text="$1"
  if [ -z "$SLACK_WEBHOOK_URL" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  local payload
  payload="{\"text\": $(printf '%s' "$text" | json_escape)}"
  curl -sS -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null
}

fail_hard() {
  local msg="$1"
  echo "monitor error: $msg" >&2
  [ -n "$SLACK_WEBHOOK_URL" ] && post_slack "check-process-status FAILED on $HOSTNAME_SHORT: $msg"
  exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  command -v tmux >/dev/null 2>&1 || fail_hard "tmux not installed"
  [ -f "$MANIFEST" ] || fail_hard "manifest not found: $MANIFEST"

  local -a M_TYPE M_ROLE M_TARGET M_LABEL
  local type role target label
  while read -r type role target label; do
    case "$type" in ''|\#*) continue ;; esac
    [ -z "$target" ] && continue
    M_TYPE+=("$type"); M_ROLE+=("$role"); M_TARGET+=("$target"); M_LABEL+=("$label")
  done < "$MANIFEST"

  local n=${#M_TARGET[@]}
  [ "$n" -gt 0 ] || fail_hard "manifest has no entries: $MANIFEST"

  WORKDIR="$(mktemp -d)" || fail_hard "mktemp failed"
  trap 'rm -rf "${WORKDIR:-}"' EXIT

  local -a STATUS PID
  local i cmd ppid child
  for ((i=0; i<n; i++)); do
    target="${M_TARGET[$i]}"
    cmd="$(tmux display -p -t "$target" '#{pane_current_command}' 2>/dev/null)"
    if [ -z "$cmd" ]; then
      STATUS[$i]="MISSING"; PID[$i]=""
    elif is_shell_cmd "$cmd"; then
      STATUS[$i]="DEAD"; PID[$i]=""
    else
      STATUS[$i]="ALIVE"
      ppid="$(tmux display -p -t "$target" '#{pane_pid}' 2>/dev/null)"
      # binary is usually the pane shell's child (send-keys ./bin); if tmux
      # launched the command directly, the pane pid IS the process.
      child="$(pgrep -P "$ppid" 2>/dev/null | head -1)"
      PID[$i]="${child:-$ppid}"
    fi
    # phase-1 snapshot for live subscribers
    if [ "${M_ROLE[$i]}" = "sub" ] && [ "${STATUS[$i]}" = "ALIVE" ]; then
      tmux capture-pane -p -t "$target" 2>/dev/null | last_nonempty_line > "$WORKDIR/snap1_$i"
    fi
  done

  # single wait shared by every subscriber, then phase-2 snapshot
  sleep "$WAIT_SECONDS"

  local -a RECV
  for ((i=0; i<n; i++)); do
    RECV[$i]=""
    if [ "${M_ROLE[$i]}" = "sub" ] && [ "${STATUS[$i]}" = "ALIVE" ]; then
      tmux capture-pane -p -t "${M_TARGET[$i]}" 2>/dev/null | last_nonempty_line > "$WORKDIR/snap2_$i"
      if diff -q "$WORKDIR/snap1_$i" "$WORKDIR/snap2_$i" >/dev/null 2>&1; then
        RECV[$i]="STALL"
      else
        RECV[$i]="RECV"
      fi
    fi
  done

  # per-process RSS (KB) and CPU for live targets
  local -a RSS CPU
  local psline
  for ((i=0; i<n; i++)); do
    RSS[$i]=""; CPU[$i]=""
    if [ -n "${PID[$i]}" ]; then
      psline="$(ps -o rss=,pcpu= -p "${PID[$i]}" 2>/dev/null)"
      RSS[$i]="$(echo "$psline" | awk '{print $1}')"
      CPU[$i]="$(echo "$psline" | awk '{print $2}')"
    fi
  done

  # ---- aggregate ----
  local alive=0 subs=0 recv=0 memmax=0
  local -a ALERTS
  local lbl a
  for ((i=0; i<n; i++)); do
    [ "${STATUS[$i]}" = "ALIVE" ] && alive=$((alive+1))
    [ "${M_ROLE[$i]}" = "sub" ] && subs=$((subs+1))
    [ "${RECV[$i]}" = "RECV" ] && recv=$((recv+1))
    if [ -n "${RSS[$i]}" ] && [ "${RSS[$i]}" -gt "$memmax" ]; then
      memmax="${RSS[$i]}"
    fi

    lbl="${M_LABEL[$i]} ${M_ROLE[$i]}"
    case "${STATUS[$i]}" in
      MISSING) ALERTS+=("[MISS]  $lbl  (no tmux target)") ;;
      DEAD)    ALERTS+=("[DEAD]  $lbl  (pane back to shell)") ;;
      ALIVE)
        if [ "${RECV[$i]}" = "STALL" ]; then
          ALERTS+=("[STALL] $lbl  no new line in ${WAIT_SECONDS}s")
        fi
        if [ -n "${RSS[$i]}" ] && rss_exceeds "${RSS[$i]}" "$MEM_THRESHOLD_MB"; then
          ALERTS+=("[MEM]   $lbl  $(human_kb "${RSS[$i]}") > ${MEM_THRESHOLD_MB}M")
        fi
        ;;
    esac
  done

  # ---- build report ----
  local R="$WORKDIR/report"
  {
    echo "int2dds long-term  |  $HOSTNAME_SHORT  |  $(date '+%F %H:%M')"
    echo "alive ${alive}/${n}   sub-receiving ${recv}/${subs}   mem-max $(human_kb "$memmax") (thr ${MEM_THRESHOLD_MB}M)"
    echo ""
    if [ "${#ALERTS[@]}" -gt 0 ]; then
      echo "ALERTS:"
      for a in "${ALERTS[@]}"; do echo "$a"; done
    else
      echo "ALERTS: none (all green)"
    fi
    echo ""
    echo "PROCESSES (test only):"
    free -m 2>/dev/null | awk '/^Mem:/{m=sprintf("Mem %d/%dMB", $3, $2)} /^Swap:/{s=sprintf("Swap %d/%dMB", $3, $2)} END{printf "%s  %s", m, s}'
    echo "  load$(uptime 2>/dev/null | sed 's/.*load average[s]*:/ /')"
    printf '%-30s %-4s %-7s %-6s %-7s %s\n' "LABEL" "ROLE" "STATUS" "RECV" "%CPU" "RSS"
    for ((i=0; i<n; i++)); do
      local rss_h="-"
      [ -n "${RSS[$i]}" ] && rss_h="$(human_kb "${RSS[$i]}")"
      printf '%-30s %-4s %-7s %-6s %-7s %s\n' \
        "${M_LABEL[$i]}" "${M_ROLE[$i]}" "${STATUS[$i]}" "${RECV[$i]:--}" "${CPU[$i]:--}" "$rss_h"
    done
  } > "$R"

  post_slack "\`\`\`
$(cat "$R")
\`\`\`"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
