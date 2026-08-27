#!/usr/bin/env bash
set -u

PASS=0
FAIL=0

assert() {
  local desc="$1"
  if eval "$2" >/dev/null 2>&1; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

PANEL="https://127.0.0.1:3001"
STRUXA="/opt/struxa"
WINGS="/opt/wings"
CFG="/etc/pterodactyl/config.yml"

PINNED=false
[[ -f "${STRUXA}/.test_pin" ]] && PINNED=true

wait_http() {
  local tries=36
  while true; do
    [[ "$(curl -sk -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)" == "200" ]] && return 0
    tries=$((tries - 1))
    [[ $tries -le 0 ]] && return 1
    sleep 5
  done
}

echo "== Struxa installer test suite ($(hostname)) =="

# ── 1. Containers ────────────────────────────────────────────────────────────
cd "$STRUXA"
assert "struxa compose ps succeeds" 'docker compose -f docker-compose.prod.yml --env-file .env.prod ps >/dev/null'
for svc in mysql minio web watchkeeper; do
  assert "container ${svc} is running" "docker compose -f ${STRUXA}/docker-compose.prod.yml --env-file ${STRUXA}/.env.prod ps --status running ${svc} | grep -q ${svc}"
done
assert "migrate container exited cleanly" "docker compose -f ${STRUXA}/docker-compose.prod.yml --env-file ${STRUXA}/.env.prod ps -a migrate | grep -q 'Exited (0)'"
assert "wings container is running" "docker compose -f ${WINGS}/compose.yml ps | grep -q Up"

# ── 2. Panel reachable ───────────────────────────────────────────────────────
assert "panel responds 200 on 127.0.0.1:3001" "wait_http ${PANEL}/"
assert "panel responds 200 through nginx (panel.test)" "curl -sk --resolve panel.test:443:127.0.0.1 https://panel.test/ -o /dev/null -w '%{http_code}' | grep -q 200"

if ! $PINNED; then
  # ── 3. Admin account (bootstrap) ───────────────────────────────────────────
  assert "admin can sign in via better-auth" "curl -sk -X POST ${PANEL}/api/auth/sign-in/email -H 'Content-Type: application/json' -d '{\"email\":\"admin@struxa.test\",\"password\":\"testpass12345\"}' -o /dev/null -w '%{http_code}' | grep -q 200"
  assert "setup wizard redirects away (/setup -> 3xx)" "curl -sk -o /dev/null -w '%{http_code}' ${PANEL}/setup | grep -q '^30[0-9]$'"

  # ── 4. Wings config written with live values ───────────────────────────────
  assert "wings config has uuid" "grep -q '^uuid: .' ${CFG}"
  assert "wings config has token_id" "grep -q '^token_id: .' ${CFG}"
  assert "wings config has token" "grep -q '^token: .' ${CFG}"
  assert "wings config remote points at panel" "grep -q '^remote: https://panel.test\$' ${CFG}"
  assert "wings config listens on 8080 (behind proxy)" "grep -q '^  port: 8080\$' ${CFG}"
  assert "wings config ssl disabled (nginx terminates TLS)" "awk '/^  ssl:\$/{s=1} s && /enabled: false/{found=1} END{exit !found}' ${CFG}"

  # ── 5. Wings<->panel handshake (linked proof) ──────────────────────────────
  TOKEN_ID=$(awk -F': ' '/^token_id:/{print $2; exit}' "$CFG")
  TOKEN=$(awk -F': ' '/^token:/{print $2; exit}' "$CFG")
  assert "wings token authenticates against /api/remote/servers" "curl -sk -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ${TOKEN_ID}.${TOKEN}' ${PANEL}/api/remote/servers | grep -q 200"
  assert "wings token authenticates against /api/remote/activity" "curl -sk -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer ${TOKEN_ID}.${TOKEN}' -H 'Content-Type: application/json' -d '{\"data\":[]}' ${PANEL}/api/remote/activity | grep -q 204"

  # ── 6. Update idempotency ──────────────────────────────────────────────────
  env STRUXA_UNATTENDED=1 bash /vagrant/install.sh update --no-telemetry > /tmp/update.log 2>&1
  assert "update exits 0 on an up-to-date install" "test $? -eq 0"
  assert "update reports panel already up to date" "grep -q 'already up to date' /tmp/update.log"
else
  # ── 8. Old -> new update (pinned install) ──────────────────────────────────
  env STRUXA_UNATTENDED=1 bash /vagrant/install.sh update --no-telemetry > /tmp/update.log 2>&1
  assert "old->new update exits 0" "test $? -eq 0"
  LATEST=$(curl -fsSL https://api.github.com/repos/struxadotcloud/struxa/releases/latest -H 'Accept: application/vnd.github+json' | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  assert "IMAGE_TAG bumped to latest (${LATEST#v})" "grep -q \"^IMAGE_TAG=${LATEST#v}\" ${STRUXA}/.env.prod"
  assert "panel responds 200 after update" "wait_http ${PANEL}/"
  assert "web container running after update" "docker compose -f ${STRUXA}/docker-compose.prod.yml --env-file ${STRUXA}/.env.prod ps --status running web | grep -q web"
fi

# ── 7. Wings-only update ─────────────────────────────────────────────────────
BEFORE=$(grep '^IMAGE_TAG=' "${STRUXA}/.env.prod")
env STRUXA_UNATTENDED=1 bash /vagrant/install.sh update --wings-only --no-telemetry > /tmp/wingsonly.log 2>&1
assert "update --wings-only exits 0" "test $? -eq 0"
assert "update --wings-only leaves IMAGE_TAG unchanged" "test \"$(grep '^IMAGE_TAG=' ${STRUXA}/.env.prod)\" == \"${BEFORE}\""
assert "wings container running after wings-only update" "docker compose -f ${WINGS}/compose.yml ps | grep -q Up"

# ── 9. Installer unit tests ──────────────────────────────────────────────────
bash /vagrant/tests/unit.sh > /tmp/unit.log 2>&1
if [[ $? -eq 0 ]]; then
  assert "installer unit tests pass" true
else
  cat /tmp/unit.log
  assert "installer unit tests pass" false
fi

echo
echo "== Results: ${PASS} passed, ${FAIL} failed =="
[[ $FAIL -eq 0 ]]
