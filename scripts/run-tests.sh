#!/usr/bin/env bash
set -uo pipefail

KEEP=false
BOXES=("ubuntu2204" "ubuntu2404" "debian13")
PIN_TAG="${STRUXA_TEST_PIN_TAG:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --box) BOXES=("$2"); shift 2 ;;
    --keep) KEEP=true; shift ;;
    --no-pin) PIN_TAG=""; shift ;;
    --pin) PIN_TAG="$2"; shift 2 ;;
    *) echo "Usage: $0 [--box <name>] [--keep] [--pin <tag>] [--no-pin]"; exit 2 ;;
  esac
done

resolve_prev_tag() {
  curl -fsSL "https://api.github.com/repos/struxadotcloud/struxa/releases?per_page=10" \
    -H "Accept: application/vnd.github+json" | awk '
    /"tag_name"/ { tag = $0 }
    /"prerelease": false/ {
      match(tag, /"tag_name": *"([^"]+)"/, a)
      if (a[1]) {
        count++
        if (count == 2) { print a[1]; exit }
      }
    }' | sed 's/^v//'
}

if [[ -z "$PIN_TAG" ]]; then
  PIN_TAG=$(resolve_prev_tag || true)
fi

if [[ -n "$PIN_TAG" ]]; then
  echo "Pinning ubuntu2204 install to previous release: ${PIN_TAG}"
else
  echo "No previous release found — the old->new update test will be skipped (unpinned installs)."
fi

results=()

for box in "${BOXES[@]}"; do
  echo
  echo "═══════ ${box} ═══════"

  echo "==> vagrant up ${box}"
  if ! STRUXA_TEST_PIN_TAG="$PIN_TAG" vagrant up "$box"; then
    results+=("${box}: UP FAILED")
    continue
  fi

  echo "==> provisioning (install) ${box}"
  if ! STRUXA_TEST_PIN_TAG="$PIN_TAG" vagrant provision "$box"; then
    results+=("${box}: PROVISION FAILED")
    if ! $KEEP; then vagrant destroy -f "$box"; fi
    continue
  fi

  echo "==> running test suite on ${box}"
  if vagrant ssh "$box" -c 'sudo bash /vagrant/tests/run.sh'; then
    results+=("${box}: PASS")
  else
    results+=("${box}: FAIL")
  fi

  if ! $KEEP; then
    vagrant destroy -f "$box"
  fi
done

echo
echo "Results:"
for r in "${results[@]}"; do
  echo "  ${r}"
done

for r in "${results[@]}"; do
  [[ "$r" == *": PASS" ]] || { echo "Some tests failed."; exit 1; }
done
echo "All tests passed."
