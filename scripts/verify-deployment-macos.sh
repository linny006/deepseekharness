#!/usr/bin/env bash
set -uo pipefail

LABEL="com.deepseek.harness.web"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WEB_LOG="$HOME/dsh/backups/web.out.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

check() {
  local name="$1"
  shift
  if eval "$@"; then
    printf 'PASS: %s\n' "$name"
    ((pass++))
  else
    printf 'FAIL: %s\n' "$name"
    ((fail++))
  fi
}

check "launchd plist exists" test -f "$PLIST"
check "launchd plist valid" plutil -lint "$PLIST"
check "web service active" "launchctl print gui/$(id -u)/$LABEL | grep -q 'state = running'"
check "web listens on loopback" "lsof -nP -iTCP:3080 -sTCP:LISTEN | grep -q '127\\.0\\.0\\.1:3080'"
check "web does not listen publicly" "! lsof -nP -iTCP:3080 -sTCP:LISTEN | grep -Eq '(\\*|0\\.0\\.0\\.0|\\[::\\]):3080'"
check "web auth challenge" 'code="$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/ || true)"; [[ "$code" == "401" ]]'

token=$(grep -o 'token=[A-Za-z0-9_-]*' "$WEB_LOG" 2>/dev/null | tail -1 | cut -d= -f2)
check "web token available" test -n "$token"
check "web accepts token" 'code="$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:3080/?token=$token" || true)"; [[ "$code" =~ ^(200|303)$ ]]'

check "relay control connection online" 'grep -q "server control connection online" "$WEB_LOG"'
check "relay credentials private" '[[ "$(stat -f %Lp "$HOME/.dsh/ds-harness-remote/servers/22c362b08529bf99a3e425b7/host/server-credentials.json")" == "600" ]]'
check "env private" '[[ "$(stat -f %Lp "$HOME/.dsh/.env")" == "600" ]]'
check "web log private" '[[ "$(stat -f %Lp "$WEB_LOG")" == "600" ]]'
check "web error log private" '[[ "$(stat -f %Lp "$HOME/dsh/backups/web.err.log")" == "600" ]]'
check "backups directory private" '[[ "$(stat -f %Lp "$HOME/dsh/backups")" == "700" ]]'
check "dsh home symlink" '[[ "$(readlink "$HOME/.dsh")" == "$HOME/dsh/home" ]]'
check "apps symlink" '[[ "$(readlink "$HOME/apps")" == "$HOME/dsh/apps" ]]'
check "projects symlink" '[[ "$(readlink "$HOME/projects")" == "$HOME/dsh/projects" ]]'
check "node 24" '[[ "$("$HOME/.nvm/versions/node/v24.22.3/bin/node" -v)" =~ ^v24\. ]]'
check "dsh version" '[[ "$(PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v24.22.3/bin:$PATH" dsh -V)" == "0.2.2-rc.2" ]]'
check "pi-ai patch" '"$SCRIPT_DIR/apply-pi-ai-patch-macos.sh" --check'

printf '\nSummary: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
