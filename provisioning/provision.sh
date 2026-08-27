#!/usr/bin/env bash
set -euo pipefail

grep -q 'panel.test' /etc/hosts || cat >> /etc/hosts << 'HOSTS'
127.0.0.1 panel.test
127.0.0.1 wings.test
HOSTS

INSTALL_ENV=(
  STRUXA_UNATTENDED=1
  STRUXA_MODE=wings
  STRUXA_PANEL_DOMAIN=panel.test
  STRUXA_WINGS_DOMAIN=wings.test
  STRUXA_EMAIL=admin@struxa.test
  STRUXA_PASSWORD=testpass12345
  STRUXA_LOCATION_NAME='Test Location'
  STRUXA_NODE_NAME='Test Node'
  STRUXA_WEBSERVER=nginx
  STRUXA_SSL=selfsigned
)

if [[ -n "${STRUXA_TEST_PIN_TAG:-}" ]]; then
  INSTALL_ENV+=(STRUXA_IMAGE_TAG="$STRUXA_TEST_PIN_TAG")
  echo "$STRUXA_TEST_PIN_TAG" > /opt/struxa/.test_pin
fi

env "${INSTALL_ENV[@]}" bash /vagrant/install.sh --no-telemetry
