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

NO_TELEMETRY=true

SCRIPT_FRAGMENT=$(sed '/^# ═/,$d' /vagrant/install.sh)
eval "$SCRIPT_FRAGMENT"

echo "== install.sh unit tests =="

# ── distro detection ─────────────────────────────────────────────────────────
EXPECTED="$(sed -n 's/^ID=//p' /etc/os-release | head -1 | tr -d '"')_$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -1 | tr -d '"')"
assert "distro_id matches /etc/os-release" "test \"\$(distro_id)\" == \"${EXPECTED}\""

# ── version comparison ───────────────────────────────────────────────────────
assert "ver_compare picks the smaller version" "test \"\$(ver_compare 1.4.0 1.5.0)\" == 1.4.0"
assert "ver_compare strips leading v" "test \"\$(ver_compare v1.4.0 v1.5.0)\" == 1.4.0"
assert "ver_compare handles equal versions" "test \"\$(ver_compare 1.5.0 1.5.0)\" == 1.5.0"
assert "ver_compare handles multi-digit components" "test \"\$(ver_compare 1.4.10 1.4.2)\" == 1.4.2"

# ── json escaping ────────────────────────────────────────────────────────────
ESC=$(printf 'a"b\nc' | json_escape)
assert "json_escape escapes double quotes" "[[ \"${ESC}\" == *'\\\\\"'* ]]"
assert "json_escape removes literal newlines" "[[ \"${ESC}\" != *\$'\n'* ]]"

# ── secret scrubbing ─────────────────────────────────────────────────────────
MYSQL_PASSWORD="super_secret_pw"
SCRUBBED=$(printf 'password is super_secret_pw' | scrub_secrets)
assert "scrub_secrets redacts known secret values" "test \"${SCRUBBED}\" == 'password is [REDACTED]'"
assert "scrub_secrets leaves unrelated text intact" "test \"\$(echo hello | scrub_secrets)\" == hello"

# ── unattended prompt helpers ────────────────────────────────────────────────
assert "ask_yn unattended defaults to yes" "STRUXA_UNATTENDED=1 ask_yn test y"
assert "ask_yn unattended defaults to no" "! STRUXA_UNATTENDED=1 ask_yn test n"

# ── unattended validation ────────────────────────────────────────────────────
assert "validate_unattended rejects missing vars" "! ( STRUXA_UNATTENDED=1 MODE=install validate_unattended >/dev/null 2>&1 )"
assert "validate_unattended accepts complete env" "( STRUXA_UNATTENDED=1 MODE=install STRUXA_PANEL_DOMAIN=p.test STRUXA_EMAIL=a@b.c STRUXA_PASSWORD=12345678 STRUXA_WINGS_DOMAIN=w.test validate_unattended >/dev/null 2>&1 )"
assert "validate_unattended rejects short password" "! ( STRUXA_UNATTENDED=1 MODE=install STRUXA_PANEL_DOMAIN=p.test STRUXA_EMAIL=a@b.c STRUXA_PASSWORD=short STRUXA_WINGS_DOMAIN=w.test validate_unattended >/dev/null 2>&1 )"
assert "validate_unattended rejects bad email" "! ( STRUXA_UNATTENDED=1 MODE=install STRUXA_PANEL_DOMAIN=p.test STRUXA_EMAIL=not-an-email STRUXA_PASSWORD=12345678 STRUXA_WINGS_DOMAIN=w.test validate_unattended >/dev/null 2>&1 )"
assert "validate_unattended rejects bad ssl mode" "! ( STRUXA_UNATTENDED=1 MODE=install STRUXA_PANEL_DOMAIN=p.test STRUXA_EMAIL=a@b.c STRUXA_PASSWORD=12345678 STRUXA_WINGS_DOMAIN=w.test STRUXA_SSL=bogus validate_unattended >/dev/null 2>&1 )"

# ── release resolution ───────────────────────────────────────────────────────
assert "resolve_release_tag honors STRUXA_IMAGE_TAG pin" "( STRUXA_IMAGE_TAG=9.9.9 resolve_release_tag >/dev/null 2>&1 && test \"\$RESOLVED_TAG\" == v9.9.9 )"

# ── install id persistence ───────────────────────────────────────────────────
if [[ $EUID -eq 0 && -f /opt/struxa/.install_id ]]; then
  assert "install id matches stored value" "test \"\$(ensure_install_id && echo \$STRUXA_DISTINCT_ID)\" == \"\$(cat /opt/struxa/.install_id)\""
fi

# ── black-box invocations ────────────────────────────────────────────────────
bash /vagrant/install.sh --panel-only --wings-only --no-telemetry >/dev/null 2>&1
assert "mutually exclusive flags are rejected" "test $? -eq 1"

STRUXA_UNATTENDED=1 bash /vagrant/install.sh --no-telemetry >/tmp/unattended.log 2>&1
assert "unattended install without required vars exits 1" "test $? -eq 1"
assert "validation failure lists missing vars" "grep -q STRUXA_PANEL_DOMAIN /tmp/unattended.log"

if [[ $EUID -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
  runuser -u nobody -- bash /vagrant/install.sh --no-telemetry >/dev/null 2>&1
  assert "non-root execution is rejected" "test $? -eq 1"
fi

echo "== Results: ${PASS} passed, ${FAIL} failed =="
[[ $FAIL -eq 0 ]]
