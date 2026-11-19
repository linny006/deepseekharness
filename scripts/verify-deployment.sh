#!/usr/bin/env bash
set -uo pipefail

pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$name"
    ((pass++))
  else
    printf 'FAIL: %s\n' "$name"
    ((fail++))
  fi
}

check "service active" systemctl is-active --quiet deepseek-harness
check "service enabled" systemctl is-enabled --quiet deepseek-harness
check "node 24" bash -c '[[ "$(sudo -iu dsh bash -lc "node -v")" =~ ^v24\. ]]'
check "dsh version" bash -c '[[ "$(sudo -iu dsh bash -lc "dsh -V")" =~ ^0\.2\.2-rc\.[0-9]+$ ]]'
check "web loopback" bash -c 'sudo ss -lntp | grep -E "127\.0\.0\.1:3080" >/dev/null'
check "web not public" bash -c '! sudo ss -lntp | grep -E "(0\.0\.0\.0|\[::\]):3080" >/dev/null'
check "web returns auth challenge" bash -c '[[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/)" == "401" ]]'
check "remote relay container healthy" bash -c 'sudo docker compose -f /mnt/data/dsh-remote-server/compose.yaml --project-directory /mnt/data/dsh-remote-server ps --format json | grep -q "\"Health\":\"healthy\""'
check "remote relay loopback" bash -c 'sudo ss -lntp | grep -E "127\.0\.0\.1:8080" >/dev/null'
check "remote relay not public" bash -c '! sudo ss -lntp | grep -E "(0\.0\.0\.0|\[::\]):8080" >/dev/null'
check "remote https entry" bash -c '[[ "$(curl -s -o /dev/null -w "%{http_code}" https://dsh.spectracodeai.com/app/login)" == "200" ]]'
check "remote plugin installed" bash -c 'sudo -iu dsh test -d /mnt/data/dsh/home/profiles/web/node_modules/ds-harness-remote'
check "dsh docker access" bash -c 'sudo -iu dsh docker ps >/dev/null'
check "dsh cannot read ubuntu ssh" bash -c '! sudo -iu dsh test -r /home/ubuntu/.ssh'
check "credentials private" bash -c '[[ "$(sudo stat -c %a /mnt/data/dsh/home/.credentials.yaml)" == "600" ]]'
check "env private" bash -c '[[ "$(sudo stat -c %a /mnt/data/dsh/home/.env)" == "600" ]]'
check "datadisk layout" bash -c '[[ "$(sudo readlink /home/dsh/.dsh)" == "/mnt/data/dsh/home" ]]'
check "pi-ai patch" sudo -iu dsh /mnt/data/deepseekharness/scripts/apply-pi-ai-patch.sh --check

printf '\nSummary: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
