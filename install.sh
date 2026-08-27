#!/usr/bin/env bash
# Struxa Installer — sets up Struxa dashboard and optionally Wings node agent

# Redirect stdin from the terminal so interactive prompts work when the script
# is fetched via curl (curl | bash pipes stdin; bash <(curl) does not).
# Skipped when there is no terminal at all (e.g. vagrant provision) — the
# unattended mode never reads from /dev/tty anyway.
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
  exec < /dev/tty
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd || true)"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Output helpers ───────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}  →${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${RESET} $*"; }
err()     { echo -e "${RED}  ✗${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }
step()    { echo -e "${BOLD}  ▸ $*${RESET}"; }
blank()   { echo ""; }

# ── Banner ───────────────────────────────────────────────────────────────────
show_banner() {
  echo -e "${CYAN}${BOLD}"
  cat << 'BANNER'
   ██████╗████████╗██████╗ ██╗   ██╗██╗  ██╗ █████╗
  ██╔════╝╚══██╔══╝██╔══██╗██║   ██║╚██╗██╔╝██╔══██╗
  ███████╗   ██║   ██████╔╝██║   ██║ ╚███╔╝ ███████║
  ╚════██║   ██║   ██╔══██╗██║   ██║ ██╔██╗ ██╔══██║
  ███████║   ██║   ██║  ██║╚██████╔╝██╔╝ ██╗██║  ██║
  ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
BANNER
  echo -e "${RESET}${DIM}             Game Server Management Platform${RESET}"
  echo -e "${DIM}                      Installer v1.0${RESET}"
  echo -e "${DIM}   Sends anonymous install stats. Opt out: --no-telemetry${RESET}"
  blank
}

# ── Root check ───────────────────────────────────────────────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Try: sudo bash install.sh"
    fail_event "root_check"
    exit 1
  fi
}

# ── Input helpers ────────────────────────────────────────────────────────────
ask_yn() {
  local prompt="$1" default="${2:-y}" reply
  local hint; [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  if [[ "${STRUXA_UNATTENDED:-}" == "1" ]]; then
    echo -e "${BOLD}  ? ${RESET}${prompt} ${DIM}${hint}${RESET} ${DIM}(unattended)${RESET}" >&2
    [[ "$default" == "y" ]] && return 0 || return 1
  fi
  while true; do
    echo -en "${BOLD}  ? ${RESET}${prompt} ${DIM}${hint}${RESET} " >&2
    read -r reply </dev/tty
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo -e "${YELLOW}  ⚠${RESET} Please answer y or n." >&2 ;;
    esac
  done
}

# All display in ask_input/ask_secret/ask_select goes to stderr — not stdout,
# so calling them inside $() command substitution doesn't swallow the
# prompts; not /dev/tty either, so ordering stays correct relative to the
# rest of the script's output once stdout/stderr are piped through a logger.
ask_input() {
  local prompt="$1" default="${2:-}" result
  if [[ "${STRUXA_UNATTENDED:-}" == "1" ]]; then
    err "ask_input (${prompt}) reached in unattended mode — missing STRUXA_* variable?"
    fail_event "unattended_prompt"
    exit 1
  fi
  if [[ -n "$default" ]]; then
    echo -en "${BOLD}  ? ${RESET}${prompt} ${DIM}[${default}]${RESET}: " >&2
  else
    echo -en "${BOLD}  ? ${RESET}${prompt}: " >&2
  fi
  read -r result </dev/tty
  echo "${result:-$default}"
}

ask_secret() {
  local prompt="$1" result
  if [[ "${STRUXA_UNATTENDED:-}" == "1" ]]; then
    err "ask_secret (${prompt}) reached in unattended mode — missing STRUXA_* variable?"
    fail_event "unattended_prompt"
    exit 1
  fi
  echo -en "${BOLD}  ? ${RESET}${prompt} ${DIM}(hidden)${RESET}: " >&2
  read -rs result </dev/tty
  echo "" >&2
  echo "$result"
}

ask_select() {
  local prompt="$1"; shift
  local options=("$@") choice i=1
  if [[ "${STRUXA_UNATTENDED:-}" == "1" ]]; then
    err "ask_select (${prompt}) reached in unattended mode — missing STRUXA_* variable?"
    fail_event "unattended_prompt"
    exit 1
  fi
  echo -e "${BOLD}  ? ${RESET}${prompt}" >&2
  for opt in "${options[@]}"; do
    echo -e "     ${CYAN}[${i}]${RESET} ${opt}" >&2
    (( i++ )) || true
  done
  while true; do
    echo -en "  ${BOLD}→${RESET} Choice: " >&2
    read -r choice </dev/tty
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "$choice"
      return
    fi
    echo -e "${YELLOW}  ⚠${RESET} Enter a number between 1 and ${#options[@]}." >&2
  done
}

# ── Secret generators ────────────────────────────────────────────────────────
generate_secret() { openssl rand -hex 32; }
generate_hex64()  { openssl rand -hex 32; }  # outputs 64 hex chars

GENERATED_PRIVATE_KEY=""
GENERATED_PUBLIC_KEY=""

generate_rsa_keypair() {
  local tmp
  tmp=$(mktemp -d)
  openssl genrsa -out "${tmp}/priv.pem" 2048 2>/dev/null
  openssl rsa -in "${tmp}/priv.pem" -pubout -out "${tmp}/pub.pem" 2>/dev/null
  GENERATED_PRIVATE_KEY=$(base64 -w0 < "${tmp}/priv.pem")
  GENERATED_PUBLIC_KEY=$(base64 -w0 < "${tmp}/pub.pem")
  rm -rf "$tmp"
}

# ── Spinner ──────────────────────────────────────────────────────────────────
_SPINNER_PID=""

start_spinner() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  (
    while true; do
      for f in "${frames[@]}"; do
        echo -en "\r  ${CYAN}${f}${RESET} ${msg}  "
        sleep 0.08
      done
    done
  ) &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
    echo -en "\r\033[K"
  fi
}

# Runs "$@", capturing its output. On failure, dumps that output to stderr
# (which the installer log also captures) so silent commands leave a trail.
run_logged() {
  local tmp rc=0
  tmp=$(mktemp)
  "$@" > "$tmp" 2>&1 || rc=$?
  [[ $rc -ne 0 ]] && cat "$tmp" >&2
  rm -f "$tmp"
  return "$rc"
}

# Clean up spinner on exit
trap 'stop_spinner' EXIT

# ── Argument parsing ─────────────────────────────────────────────────────────
USE_NIGHTLY=false
MODE="install"
NO_TELEMETRY=false
PANEL_ONLY=false
WINGS_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --nightly)      USE_NIGHTLY=true ;;
    --no-telemetry) NO_TELEMETRY=true ;;
    --panel-only)   PANEL_ONLY=true ;;
    --wings-only)   WINGS_ONLY=true ;;
    update)         MODE="update" ;;
    uninstall|remove) MODE="uninstall" ;;
  esac
done
[[ -n "${DO_NOT_TRACK:-}" ]] && NO_TELEMETRY=true
[[ -n "${STRUXA_NO_TELEMETRY:-}" ]] && NO_TELEMETRY=true
if $PANEL_ONLY && $WINGS_ONLY; then
  err "--panel-only and --wings-only are mutually exclusive."
  exit 1
fi

# ── Telemetry ─────────────────────────────────────────────────────────────────
# Anonymous install analytics (event name + OS/arch/mode, no domains or secrets).
# Opt out with --no-telemetry, STRUXA_NO_TELEMETRY=1, or DO_NOT_TRACK=1.
POSTHOG_HOST="https://eu.i.posthog.com"
POSTHOG_KEY="phc_wJVWqWPQjfae28vTDvyoU4rxm5HcrQVxzsSkooL6REsM"

# Persistent anonymous install id so events from the same machine correlate.
# Falls back to a per-run uuid when /opt/struxa is not writable (non-root).
STRUXA_DISTINCT_ID=""
ensure_install_id() {
  if [[ -f /opt/struxa/.install_id ]]; then
    STRUXA_DISTINCT_ID=$(cat /opt/struxa/.install_id)
    return
  fi
  local new_id
  new_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
  if [[ $EUID -eq 0 ]] && mkdir -p /opt/struxa 2>/dev/null; then
    echo "$new_id" > /opt/struxa/.install_id
    chmod 600 /opt/struxa/.install_id 2>/dev/null || true
  fi
  STRUXA_DISTINCT_ID="$new_id"
}
ensure_install_id

distro_id() {
  if [[ -f /etc/os-release ]]; then
    local id ver pretty
    id=$(sed -n 's/^ID=//p' /etc/os-release | head -1 | tr -d '"')
    ver=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -1 | tr -d '"')
    if [[ -n "$id" ]]; then
      echo "${id}${ver:+_${ver}}"
      return
    fi
    pretty=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -1 | tr -d '"')
    if [[ -n "$pretty" ]]; then
      echo "$pretty"
      return
    fi
  fi
  echo "unknown"
}

json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g' -e 's/\r//g' -e 's/\t/\\t/g'
}

# Replaces every known secret value in stdin with [REDACTED]. Used before
# sending log tails in telemetry; the on-disk log itself is untouched.
scrub_secrets() {
  local script_file var val
  script_file=$(mktemp)
  for var in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD BETTER_AUTH_SECRET DATABASE_ENCRYPTION_KEY MINIO_ACCESS_KEY MINIO_SECRET_KEY TURNSTILE_SECRET_KEY BOOTSTRAP_SECRET ADMIN_PASSWORD ADMIN_EMAIL JWT_PRIVATE_KEY JWT_PUBLIC_KEY; do
    val="${!var}"
    [[ -n "$val" ]] && printf 's/%s/[REDACTED]/g\n' "$(printf '%s' "$val" | sed 's/[][\/&|]/\\&/g')" >> "$script_file"
  done
  sed -f "$script_file"
  rm -f "$script_file"
}

# $1 = event name, $2 = extra JSON properties, e.g. '"mode":"install"'
# Fire-and-forget: backgrounded with a short timeout so a slow/unreachable
# PostHog never delays or breaks the install.
send_event() {
  $NO_TELEMETRY && return 0
  # --retry: the very first event fires right after the banner, before any
  # prereq checks, so on a freshly-booted VM DNS/networking may not be up
  # yet. Retries absorb that without blocking the install (still backgrounded).
  curl -fsSL --max-time 5 --retry 2 --retry-delay 2 --retry-connrefused -X POST "$POSTHOG_HOST/capture/" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\":\"$POSTHOG_KEY\",\"event\":\"$1\",\"distinct_id\":\"$STRUXA_DISTINCT_ID\",\"properties\":{$2,\"\$ip\":null,\"os\":\"$(uname -s)\",\"arch\":\"$(uname -m)\",\"distro\":\"$(distro_id)\"}}" \
    >/dev/null 2>&1 &
}

# Failure events carry a scrubbed tail of the installer log, not just a stage tag.
fail_event() {
  local stage="$1" error=""
  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    error=$(tail -n 30 "$LOG_FILE" | scrub_secrets | json_escape | cut -c1-2000)
  fi
  send_event "installer_failed" "\"stage\":\"${stage}\",\"error\":\"${error}\""
}

# ── Unattended mode validation ───────────────────────────────────────────────
validate_unattended() {
  [[ "${STRUXA_UNATTENDED:-}" == "1" ]] || return 0
  [[ "$MODE" != "install" ]] && return 0
  local problems=()
  [[ -n "${STRUXA_PANEL_DOMAIN:-}" ]] || problems+=("STRUXA_PANEL_DOMAIN")
  [[ -n "${STRUXA_EMAIL:-}" ]] || problems+=("STRUXA_EMAIL")
  [[ ${#STRUXA_PASSWORD:-} -ge 8 ]] || problems+=("STRUXA_PASSWORD (min 8 chars)")
  [[ "${STRUXA_EMAIL:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || problems+=("STRUXA_EMAIL (valid email)")
  case "${STRUXA_MODE:-wings}" in dashboard|wings) ;; *) problems+=("STRUXA_MODE (dashboard|wings)") ;; esac
  case "${STRUXA_WEBSERVER:-nginx}" in nginx|apache|caddy|none) ;; *) problems+=("STRUXA_WEBSERVER (nginx|apache|caddy|none)") ;; esac
  case "${STRUXA_SSL:-selfsigned}" in letsencrypt|selfsigned|none) ;; *) problems+=("STRUXA_SSL (letsencrypt|selfsigned|none)") ;; esac
  [[ "${STRUXA_SSL:-selfsigned}" == "letsencrypt" && -z "${STRUXA_LETSENCRYPT_EMAIL:-}" ]] && problems+=("STRUXA_LETSENCRYPT_EMAIL (required with letsencrypt)")
  [[ "${STRUXA_MODE:-wings}" == "wings" && -z "${STRUXA_WINGS_DOMAIN:-}" ]] && problems+=("STRUXA_WINGS_DOMAIN (required with wings mode)")
  [[ "${STRUXA_NODE_MEMORY:-4096}" =~ ^[0-9]+$ ]] || problems+=("STRUXA_NODE_MEMORY (number)")
  [[ "${STRUXA_NODE_DISK:-50000}" =~ ^[0-9]+$ ]] || problems+=("STRUXA_NODE_DISK (number)")
  if [[ "${STRUXA_WEBSERVER:-nginx}" == "apache" || "${STRUXA_WEBSERVER:-nginx}" == "caddy" ]]; then
    [[ "$(detect_webserver)" == "${STRUXA_WEBSERVER}" ]] || problems+=("STRUXA_WEBSERVER=${STRUXA_WEBSERVER} requires a running ${STRUXA_WEBSERVER}")
  fi
  if [[ ${#problems[@]} -gt 0 ]]; then
    err "Unattended mode: missing or invalid environment: ${problems[*]}"
    fail_event "validation"
    exit 1
  fi
}

# ── Prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
  header "Checking Prerequisites"
  local missing=()

  # Docker
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    success "Docker is installed and running"
  else
    warn "Docker not found or daemon not running"
    if ask_yn "Install Docker automatically?"; then
      step "Installing Docker..."
      curl -fsSL https://get.docker.com | sh
      systemctl enable --now docker
      if docker info &>/dev/null 2>&1; then
        success "Docker installed"
      else
        err "Docker installation failed. Install it manually and re-run."
        fail_event "prereqs_docker"
        exit 1
      fi
    else
      missing+=("docker")
    fi
  fi

  # Docker Compose plugin
  if docker compose version &>/dev/null 2>&1; then
    success "Docker Compose plugin available"
  else
    err "Docker Compose plugin not found (package: docker-compose-plugin)."
    missing+=("docker-compose-plugin")
  fi

  # openssl
  if command -v openssl &>/dev/null; then
    success "openssl available"
  else
    err "openssl not found."
    missing+=("openssl")
  fi

  # curl
  if command -v curl &>/dev/null; then
    success "curl available"
  else
    err "curl not found."
    missing+=("curl")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    blank
    err "Missing: ${missing[*]}"
    err "Install them and re-run this script."
    fail_event "prereqs_missing"
    exit 1
  fi

  blank
  success "All prerequisites satisfied"
}

# ── Webserver detection ──────────────────────────────────────────────────────
detect_webserver() {
  if systemctl is-active --quiet nginx 2>/dev/null || (command -v nginx &>/dev/null); then
    echo "nginx"
  elif systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
    echo "apache"
  elif systemctl is-active --quiet caddy 2>/dev/null || command -v caddy &>/dev/null; then
    echo "caddy"
  else
    echo "none"
  fi
}

# ── Nginx config writers ─────────────────────────────────────────────────────
write_nginx_panel_http() {
  local domain="$1"
  cat > /etc/nginx/sites-available/struxa-panel.conf << NGXCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location / {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
}
NGXCONF
}

write_nginx_panel_ssl() {
  local domain="$1" cert="$2" key="$3"
  cat > /etc/nginx/sites-available/struxa-panel.conf << NGXCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    location / {
        proxy_pass         http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
}
NGXCONF
}

write_nginx_wings_ssl() {
  local domain="$1" cert="$2" key="$3"
  cat > /etc/nginx/sites-available/struxa-wings.conf << NGXCONF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
}
NGXCONF
}

# ── Apache config writer ─────────────────────────────────────────────────────
write_apache_panel() {
  local domain="$1" cert="$2" key="$3" ssl="$4"
  if [[ "$ssl" == "true" ]]; then
    cat > /etc/apache2/sites-available/struxa-panel.conf << APCONF
<VirtualHost *:80>
    ServerName ${domain}
    Redirect permanent / https://${domain}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${domain}
    SSLEngine on
    SSLCertificateFile    ${cert}
    SSLCertificateKeyFile ${key}

    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3001/
    ProxyPassReverse / http://127.0.0.1:3001/

    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Real-IP         %{REMOTE_ADDR}s
</VirtualHost>
APCONF
  else
    cat > /etc/apache2/sites-available/struxa-panel.conf << APCONF
<VirtualHost *:80>
    ServerName ${domain}
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3001/
    ProxyPassReverse / http://127.0.0.1:3001/
</VirtualHost>
APCONF
  fi
}

# ── Caddy config writer ──────────────────────────────────────────────────────
write_caddy_blocks() {
  local panel_domain="$1" wings_domain="${2:-}"
  local caddyfile="/etc/caddy/Caddyfile"
  [[ -f "$caddyfile" ]] && cp "$caddyfile" "${caddyfile}.bak.$(date +%s)"

  {
    echo ""
    echo "# Struxa Panel — added by installer"
    echo "${panel_domain} {"
    echo "    reverse_proxy 127.0.0.1:3001"
    echo "}"
  } >> "$caddyfile"

  if [[ -n "$wings_domain" ]]; then
    {
      echo ""
      echo "# Struxa Wings — added by installer"
      echo "${wings_domain} {"
      echo "    reverse_proxy 127.0.0.1:8080"
      echo "}"
    } >> "$caddyfile"
  fi
}

# ── Install package helper ───────────────────────────────────────────────────
pkg_install() {
  if command -v apt-get &>/dev/null; then
    apt-get install -y -qq "$@"
  elif command -v dnf &>/dev/null; then
    dnf install -y -q "$@"
  elif command -v yum &>/dev/null; then
    yum install -y -q "$@"
  else
    err "Unsupported package manager. Install ${*} manually."
    return 1
  fi
}

# ── Release tag resolution ───────────────────────────────────────────────────
RESOLVED_TAG=""
RESOLVED_IMAGE_TAG=""

resolve_release_tag() {
  local api_base="https://api.github.com/repos/struxadotcloud/struxa"

  if [[ -n "${STRUXA_IMAGE_TAG:-}" ]]; then
    RESOLVED_TAG="v${STRUXA_IMAGE_TAG}"
    RESOLVED_IMAGE_TAG="${STRUXA_IMAGE_TAG}"
    success "Release pinned via STRUXA_IMAGE_TAG: ${BOLD}${RESOLVED_TAG}${RESET}  (image tag: ${RESOLVED_IMAGE_TAG})"
    return
  fi

  if $USE_NIGHTLY; then
    step "Fetching latest pre-release tag from GitHub..."
    RESOLVED_TAG=$(curl -fsSL "${api_base}/releases?per_page=20" \
      -H "Accept: application/vnd.github+json" | \
      awk '
        /"tag_name"/ { tag = $0 }
        /"prerelease": true/ {
          match(tag, /"tag_name": *"([^"]+)"/, a)
          if (a[1]) { print a[1]; exit }
        }
      ')
    RESOLVED_IMAGE_TAG="nightly"
  else
    step "Fetching latest stable release tag from GitHub..."
    RESOLVED_TAG=$(curl -fsSL "${api_base}/releases/latest" \
      -H "Accept: application/vnd.github+json" | \
      grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    RESOLVED_IMAGE_TAG="${RESOLVED_TAG#v}"
  fi

  if [[ -z "$RESOLVED_TAG" ]]; then
    err "Could not resolve a release tag from GitHub. Check your network connection."
    fail_event "release_tag"
    exit 1
  fi

  success "Release: ${BOLD}${RESOLVED_TAG}${RESET}  (image tag: ${RESOLVED_IMAGE_TAG})"
}

# ── Update existing installation ─────────────────────────────────────────────
ver_compare() {
  printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | head -1
}

do_update() {
  header "Update Struxa"

  if [[ ! -f "${STRUXA_DIR}/.env.prod" ]]; then
    err "No existing installation found at ${STRUXA_DIR}/.env.prod"
    err "Run the installer without the update option first."
    fail_event "update_not_found"
    exit 1
  fi

  local current_tag channel="stable" panel_updated=false wings_updated=false updated="none"
  current_tag=$(grep '^IMAGE_TAG=' "${STRUXA_DIR}/.env.prod" | cut -d= -f2)
  { [[ "$current_tag" == "nightly" ]] || $USE_NIGHTLY; } && channel="nightly"

  send_event "installer_update_started" "\"channel\":\"${channel}\",\"panel_version\":\"${RESOLVED_TAG}\""

  if ! $WINGS_ONLY; then
    header "Update Panel"
    blank
    info "Current image tag : ${BOLD}${current_tag}${RESET}"
    info "Will update to    : ${BOLD}${RESOLVED_IMAGE_TAG}${RESET}  (release: ${RESOLVED_TAG})"
    blank

    if [[ "$channel" == "stable" && -n "$current_tag" && "${current_tag#v}" == "${RESOLVED_IMAGE_TAG#v}" ]]; then
      success "Panel is already up to date (${RESOLVED_IMAGE_TAG})."
    elif [[ "$channel" == "stable" && -n "$current_tag" && "$(ver_compare "$current_tag" "$RESOLVED_IMAGE_TAG")" == "${RESOLVED_IMAGE_TAG#v}" ]]; then
      warn "Current version (${current_tag}) is newer than ${RESOLVED_TAG} — skipping panel update."
    else
      warn "This will pull new images and restart all Struxa services."
      blank
      if ! ask_yn "Proceed with panel update?" "y"; then
        info "Panel update cancelled."
      else
        blank
        step "Setting IMAGE_TAG=${RESOLVED_IMAGE_TAG}..."
        sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${RESOLVED_IMAGE_TAG}/" "${STRUXA_DIR}/.env.prod"
        success "IMAGE_TAG → ${RESOLVED_IMAGE_TAG}"

        step "Checking for new required variables..."
        if ! grep -q '^MINIO_ACCESS_KEY=' "${STRUXA_DIR}/.env.prod"; then
          warn "MinIO variables not found in .env.prod — generating and appending them now."
          local new_minio_access new_minio_secret
          new_minio_access=$(generate_secret)
          new_minio_secret=$(generate_secret)
          cat >> "${STRUXA_DIR}/.env.prod" << MINIO_VARS

MINIO_ENDPOINT=http://minio:9000
MINIO_ACCESS_KEY=${new_minio_access}
MINIO_SECRET_KEY=${new_minio_secret}
MINIO_BUCKET=struxa
MINIO_VARS
          success "MinIO variables appended to .env.prod"
        fi

        step "Fetching docker-compose.prod.yml from ${RESOLVED_TAG}..."
        curl -fsSL "https://raw.githubusercontent.com/struxadotcloud/struxa/refs/tags/${RESOLVED_TAG}/docker-compose.prod.yml" \
          -o "${STRUXA_DIR}/docker-compose.prod.yml" || warn "Failed to fetch compose file — using existing."

        step "Pulling Struxa images..."
        start_spinner "Pulling images (this may take a few minutes)..."
        cd "$STRUXA_DIR"
        run_logged docker compose -f docker-compose.prod.yml --env-file .env.prod pull || {
          stop_spinner; err "Failed to pull images. Check your network connection."
          fail_event "update_pull"; exit 1
        }
        stop_spinner
        success "Images pulled"

        step "Restarting Struxa services..."
        start_spinner "Restarting services..."
        run_logged docker compose -f docker-compose.prod.yml --env-file .env.prod up -d || {
          stop_spinner; err "Failed to restart Struxa services."
          fail_event "update_restart"; exit 1
        }
        stop_spinner
        success "Struxa services updated and restarted"
        panel_updated=true
      fi
    fi
  fi

  if ! $PANEL_ONLY && [[ -f "${WINGS_DIR}/compose.yml" ]]; then
    header "Update Wings"
    blank
    warn "This will pull new Wings images and restart the Wings node agent."
    blank
    if ask_yn "Proceed with Wings update?" "y"; then
      step "Fetching wings compose.yml..."
      curl -fsSL "https://raw.githubusercontent.com/struxadotcloud/wings/master/compose.yml" \
        -o "${WINGS_DIR}/compose.yml" || warn "Failed to fetch Wings compose file — using existing."

      step "Pulling Wings images..."
      start_spinner "Pulling Wings images..."
      cd "$WINGS_DIR"
      run_logged docker compose -f compose.yml pull || {
        stop_spinner; warn "Failed to pull Wings images — check manually."
      }
      stop_spinner

      step "Restarting Wings..."
      start_spinner "Restarting Wings..."
      run_logged docker compose -f compose.yml up -d || {
        stop_spinner; warn "Failed to restart Wings — check manually."
      }
      stop_spinner
      success "Wings updated and restarted"
      wings_updated=true
    else
      info "Wings update skipped."
    fi
  fi

  if $panel_updated && $wings_updated; then updated="both"
  elif $panel_updated; then updated="panel"
  elif $wings_updated; then updated="wings"
  fi

  blank
  success "Update complete (updated: ${updated})"
  send_event "installer_update_completed" "\"panel_version\":\"${RESOLVED_TAG}\",\"channel\":\"${channel}\",\"updated\":\"${updated}\""
  exit 0
}

# ── Uninstall existing installation ──────────────────────────────────────────
do_uninstall() {
  header "Uninstall Struxa"

  if [[ ! -f "${STRUXA_DIR}/.env.prod" ]]; then
    err "No existing installation found at ${STRUXA_DIR}/.env.prod"
    fail_event "uninstall_not_found"
    exit 1
  fi

  send_event "installer_uninstall_started" ""

  local has_wings=false has_nginx=false has_apache=false has_caddy=false has_selfsigned=false
  [[ -f "${WINGS_DIR}/compose.yml" ]] && has_wings=true
  [[ -f /etc/nginx/sites-available/struxa-panel.conf ]] && has_nginx=true
  [[ -f /etc/apache2/sites-available/struxa-panel.conf ]] && has_apache=true
  grep -q "^# Struxa Panel — added by installer$" /etc/caddy/Caddyfile 2>/dev/null && has_caddy=true
  [[ -d /etc/ssl/struxa ]] && has_selfsigned=true

  blank
  info "This will stop and remove:"
  echo -e "     ${DIM}- Struxa dashboard containers${RESET}"
  $has_wings && echo -e "     ${DIM}- Wings node agent containers${RESET}"
  $has_nginx && echo -e "     ${DIM}- nginx site configs for Struxa${RESET}"
  $has_apache && echo -e "     ${DIM}- Apache site config for Struxa${RESET}"
  $has_caddy && echo -e "     ${DIM}- Caddy blocks for Struxa${RESET}"
  $has_selfsigned && echo -e "     ${DIM}- self-signed certs at /etc/ssl/struxa${RESET}"
  blank
  warn "This cannot be undone."
  blank

  if ! ask_yn "Proceed with uninstall?" "n"; then
    info "Uninstall cancelled."
    exit 0
  fi

  local delete_volumes="false"
  ask_yn "Also delete Struxa data volumes (database, uploads)? This cannot be undone." "n" && delete_volumes="true"

  blank

  if $has_wings; then
    step "Stopping Wings..."
    start_spinner "Stopping Wings containers..."
    cd "$WINGS_DIR"
    if $delete_volumes; then
      run_logged docker compose -f compose.yml down -v || warn "Failed to stop Wings — check manually."
    else
      run_logged docker compose -f compose.yml down || warn "Failed to stop Wings — check manually."
    fi
    stop_spinner
    success "Wings stopped"
  fi

  step "Stopping Struxa..."
  start_spinner "Stopping Struxa containers..."
  cd "$STRUXA_DIR"
  if $delete_volumes; then
    run_logged docker compose -f docker-compose.prod.yml --env-file .env.prod down -v || warn "Failed to stop Struxa — check manually."
  else
    run_logged docker compose -f docker-compose.prod.yml --env-file .env.prod down || warn "Failed to stop Struxa — check manually."
  fi
  stop_spinner
  success "Struxa stopped"

  if $has_nginx; then
    step "Removing nginx configuration..."
    rm -f /etc/nginx/sites-available/struxa-panel.conf /etc/nginx/sites-available/struxa-wings.conf
    rm -f /etc/nginx/sites-enabled/struxa-panel.conf /etc/nginx/sites-enabled/struxa-wings.conf
    nginx -t 2>/dev/null && systemctl reload nginx
    success "nginx configuration removed"
  fi

  if $has_apache; then
    step "Removing Apache configuration..."
    a2dissite struxa-panel 2>/dev/null || true
    rm -f /etc/apache2/sites-available/struxa-panel.conf
    apache2ctl configtest 2>/dev/null && systemctl reload apache2
    success "Apache configuration removed"
  fi

  if $has_caddy; then
    step "Removing Caddy configuration..."
    local caddyfile="/etc/caddy/Caddyfile" tmp
    cp "$caddyfile" "${caddyfile}.bak.$(date +%s)"
    tmp=$(mktemp)
    awk '
      /^# Struxa (Panel|Wings) — added by installer$/ { skip=1 }
      skip { if ($0 == "}") skip=0; next }
      { print }
    ' "$caddyfile" > "$tmp"
    mv "$tmp" "$caddyfile"
    systemctl reload caddy 2>/dev/null || true
    success "Caddy configuration removed"
  fi

  $has_selfsigned && { rm -rf /etc/ssl/struxa; success "Self-signed certs removed"; }

  if compgen -G "/etc/letsencrypt/live/*/fullchain.pem" >/dev/null 2>&1; then
    info "Let's Encrypt certificates were not removed — run 'certbot delete --cert-name <domain>' manually if desired."
  fi

  $has_wings && rm -f /etc/pterodactyl/config.yml

  blank
  if ask_yn "Delete ${STRUXA_DIR}$($has_wings && echo " and ${WINGS_DIR}"), including .env.prod and all secrets?" "y"; then
    rm -rf "$STRUXA_DIR"
    $has_wings && rm -rf "$WINGS_DIR"
    success "Installation directories removed"
  fi

  blank
  success "Uninstall complete"
  send_event "installer_uninstall_completed" ""
  echo -e "  ${DIM}Installer log:${RESET} ${LOG_FILE}"
  blank
  exit 0
}

# ── Admin account bootstrap ──────────────────────────────────────────────────
BOOTSTRAP_OK=false
BOOTSTRAP_RESPONSE=""
WINGS_LINKED=false

setup_panel_admin() {
  header "Setting Up Admin Account"
  step "Waiting for panel to become ready..."
  local attempts=0
  while [[ "$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:3001/ 2>/dev/null)" != "200" ]]; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 36 ]]; then
      err "Panel did not become ready within 3 minutes."
      fail_event "panel_timeout"
      exit 1
    fi
    sleep 5
  done
  success "Panel is up"

  local wings_json=""
  if $INSTALL_WINGS; then
    local wings_daemon_listen=443
    [[ "$URL_SCHEME" == "http" ]] && wings_daemon_listen=80
    wings_json=",\"wings\":{\"fqdn\":\"$(printf '%s' "$WINGS_DOMAIN" | json_escape)\",\"nodeName\":\"$(printf '%s' "$NODE_NAME" | json_escape)\",\"scheme\":\"${URL_SCHEME}\",\"daemonListen\":${wings_daemon_listen},\"memory\":${NODE_MEMORY},\"disk\":${NODE_DISK}}"
  fi

  step "Creating admin account${INSTALL_WINGS:+ and linking node}..."
  local body status
  body="{\"email\":\"$(printf '%s' "$ADMIN_EMAIL" | json_escape)\",\"password\":\"$(printf '%s' "$ADMIN_PASSWORD" | json_escape)\",\"name\":\"$(printf '%s' "$ADMIN_NAME" | json_escape)\",\"locationName\":\"$(printf '%s' "$LOCATION_NAME" | json_escape)\"${wings_json}}"
  BOOTSTRAP_RESPONSE=$(curl -sk -X POST "https://127.0.0.1:3001/api/setup/bootstrap" \
    -H "Content-Type: application/json" \
    -H "x-bootstrap-secret: ${BOOTSTRAP_SECRET}" \
    --data "$body" -w $'\n%{http_code}')
  status=$(echo "$BOOTSTRAP_RESPONSE" | tail -1)
  BOOTSTRAP_RESPONSE=$(echo "$BOOTSTRAP_RESPONSE" | sed '$d')

  case "$status" in
    200)
      BOOTSTRAP_OK=true
      success "Admin account created"
      ;;
    409)
      warn "Panel reports setup was already handled — continuing."
      ;;
    404)
      warn "Panel version does not support automatic setup — continuing with manual setup."
      ;;
    *)
      err "Admin setup failed (HTTP ${status}): ${BOOTSTRAP_RESPONSE}"
      fail_event "bootstrap"
      exit 1
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

STRUXA_DIR="/opt/struxa"
WINGS_DIR="/opt/wings"

# ── Logging ──────────────────────────────────────────────────────────────────
# Mirrors everything printed from here on into a timestamped log file, one
# per run, for debugging. Keeps only the LOG_KEEP most recent runs.
LOG_DIR="/var/log/struxa-install"
LOG_KEEP=10
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/struxa-install"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/$(date -u +"%Y%m%dT%H%M%SZ").log"

# shellcheck disable=SC2012
ls -1t "${LOG_DIR}"/*.log 2>/dev/null | tail -n "+$((LOG_KEEP + 1))" | xargs -r rm -f

{
  echo "════════════════════════════════════════════════════════════"
  echo "Struxa installer run: $(date -u +"%Y-%m-%dT%H:%M:%SZ")  args: $*"
  echo "Host: $(hostname 2>/dev/null || echo unknown)"
  uname -a
  [[ -f /etc/os-release ]] && cat /etc/os-release
  echo "════════════════════════════════════════════════════════════"
} >> "$LOG_FILE" 2>&1
chmod 600 "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

show_banner
send_event "installer_started" "\"action\":\"$MODE\",\"channel\":\"$([[ $USE_NIGHTLY == true ]] && echo nightly || echo stable)\""
require_root
validate_unattended
check_prereqs
[[ "$MODE" == "uninstall" ]] && do_uninstall
if [[ "$MODE" != "update" ]] || ! $WINGS_ONLY; then
  resolve_release_tag
fi

[[ "$MODE" == "update" ]] && do_update

# ── Installation mode ────────────────────────────────────────────────────────
header "Installation Mode"
if [[ "$STRUXA_UNATTENDED" == "1" ]]; then
  [[ "${STRUXA_MODE:-wings}" == "dashboard" ]] && INSTALL_MODE="1" || INSTALL_MODE="2"
else
  INSTALL_MODE=$(ask_select "What would you like to install?" \
    "Dashboard only  (Struxa panel + database)" \
    "Dashboard + Wings  (panel, database and node agent)")
fi

INSTALL_WINGS=false
[[ "$INSTALL_MODE" == "2" ]] && INSTALL_WINGS=true

# ── Create install directories & write compose files ────────────────────────
header "Preparing Install Directories"

step "Creating ${STRUXA_DIR}..."
mkdir -p "$STRUXA_DIR"

step "Fetching docker-compose.prod.yml (${RESOLVED_TAG})..."
curl -fsSL "https://raw.githubusercontent.com/struxadotcloud/struxa/refs/tags/${RESOLVED_TAG}/docker-compose.prod.yml" \
  -o "${STRUXA_DIR}/docker-compose.prod.yml" || {
  err "Failed to download Struxa compose file."
  fail_event "download_struxa_compose"
  exit 1
}
success "Struxa compose file ready"

if $INSTALL_WINGS; then
  step "Creating ${WINGS_DIR}..."
  mkdir -p "${WINGS_DIR}/config"

  step "Fetching wings compose.yml..."
  curl -fsSL "https://raw.githubusercontent.com/struxadotcloud/wings/master/compose.yml" \
    -o "${WINGS_DIR}/compose.yml" || {
    err "Failed to download Wings compose file."
    fail_event "download_wings_compose"
    exit 1
  }
  success "Wings compose file ready"
fi

# ── Dashboard configuration ──────────────────────────────────────────────────
header "Dashboard Configuration"

if [[ "$STRUXA_UNATTENDED" == "1" ]]; then
  PANEL_DOMAIN="${STRUXA_PANEL_DOMAIN}"
  ADMIN_EMAIL="${STRUXA_EMAIL}"
  ADMIN_PASSWORD="${STRUXA_PASSWORD}"
  ADMIN_NAME="${STRUXA_ADMIN_NAME:-${STRUXA_EMAIL%%@*}}"
else
  PANEL_DOMAIN=$(ask_input "Panel domain" "panel.example.com")

  blank
  step "Admin account"
  while true; do
    ADMIN_EMAIL=$(ask_input "Admin email")
    [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] && break
    warn "Please enter a valid email address."
  done
  while true; do
    ADMIN_PASSWORD=$(ask_secret "Admin password (min 8 characters)")
    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
      warn "Password must be at least 8 characters."
      continue
    fi
    ADMIN_PASSWORD_CONFIRM=$(ask_secret "Confirm admin password")
    [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]] && break
    warn "Passwords do not match — try again."
  done
  ADMIN_NAME=$(ask_input "Admin display name" "${ADMIN_EMAIL%%@*}")
fi

blank
step "Generating secure credentials..."

MYSQL_ROOT_PASSWORD=$(generate_secret)
MYSQL_DATABASE="struxa"
MYSQL_USER="struxa"
MYSQL_PASSWORD=$(generate_secret)
BETTER_AUTH_SECRET=$(generate_secret)
DATABASE_ENCRYPTION_KEY=$(generate_hex64)
MINIO_ACCESS_KEY=$(generate_secret)
MINIO_SECRET_KEY=$(generate_secret)
BOOTSTRAP_SECRET=$(generate_secret)

step "Generating RSA key pair for JWT signing..."
generate_rsa_keypair
JWT_PRIVATE_KEY="$GENERATED_PRIVATE_KEY"
JWT_PUBLIC_KEY="$GENERATED_PUBLIC_KEY"

blank
TURNSTILE_SECRET_KEY=""
if ask_yn "Configure Cloudflare Turnstile CAPTCHA?" "n"; then
  TURNSTILE_SECRET_KEY=$(ask_secret "Turnstile secret key")
fi

DATABASE_URL="mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@mysql:3306/${MYSQL_DATABASE}"
IMAGE_TAG="$RESOLVED_IMAGE_TAG"

success "Dashboard configuration ready"

# ── Wings configuration ──────────────────────────────────────────────────────
WINGS_DOMAIN=""
WINGS_TIMEZONE="UTC"
WINGS_UID="988"
WINGS_GID="988"
LOCATION_NAME="Default"
NODE_NAME=""
NODE_MEMORY="4096"
NODE_DISK="50000"

if $INSTALL_WINGS; then
  header "Wings Configuration"
  if [[ "$STRUXA_UNATTENDED" == "1" ]]; then
    WINGS_DOMAIN="${STRUXA_WINGS_DOMAIN}"
    LOCATION_NAME="${STRUXA_LOCATION_NAME:-Default}"
    NODE_NAME="${STRUXA_NODE_NAME:-${WINGS_DOMAIN}}"
    NODE_MEMORY="${STRUXA_NODE_MEMORY:-4096}"
    NODE_DISK="${STRUXA_NODE_DISK:-50000}"
  else
    WINGS_DOMAIN=$(ask_input "Wings node domain or IP" "node.example.com")
    LOCATION_NAME=$(ask_input "Location name" "Default")
    NODE_NAME=$(ask_input "Node name" "${WINGS_DOMAIN}")
  fi
  success "Wings configuration ready"
fi

# ── Webserver configuration ──────────────────────────────────────────────────
header "Webserver Configuration"

DETECTED_WS=$(detect_webserver)
WS_ACTION="skip"
SSL_MODE="none"
SSL_EMAIL=""
WEBSERVER="none"

if [[ "$STRUXA_UNATTENDED" == "1" ]]; then
  WEBSERVER="${STRUXA_WEBSERVER:-nginx}"
  SSL_MODE="${STRUXA_SSL:-selfsigned}"
  SSL_EMAIL="${STRUXA_LETSENCRYPT_EMAIL:-}"
  case "$WEBSERVER" in
    none) WS_ACTION="skip" ;;
    nginx) [[ "$DETECTED_WS" == "nginx" ]] && WS_ACTION="configure" || WS_ACTION="install_nginx" ;;
    apache|caddy) WS_ACTION="configure" ;;
  esac
elif [[ "$DETECTED_WS" != "none" ]]; then
  info "Detected: ${BOLD}${DETECTED_WS}${RESET}"
  blank
  WS_CHOICE=$(ask_select "How would you like to handle the webserver?" \
    "Configure ${DETECTED_WS} automatically  (recommended)" \
    "Install a fresh nginx and configure" \
    "Skip — just run Docker Compose without a webserver")
  case "$WS_CHOICE" in
    1) WS_ACTION="configure"; WEBSERVER="$DETECTED_WS" ;;
    2) WS_ACTION="install_nginx"; WEBSERVER="nginx" ;;
    3) WS_ACTION="skip" ;;
  esac
else
  info "No running webserver detected."
  blank
  WS_CHOICE=$(ask_select "Webserver setup:" \
    "Install nginx and configure reverse proxy  (recommended)" \
    "Skip — just run Docker Compose without a webserver")
  case "$WS_CHOICE" in
    1) WS_ACTION="install_nginx"; WEBSERVER="nginx" ;;
    2) WS_ACTION="skip" ;;
  esac
fi

if [[ "$STRUXA_UNATTENDED" != "1" && "$WS_ACTION" != "skip" ]]; then
  blank
  SSL_CHOICE=$(ask_select "SSL / HTTPS configuration:" \
    "Let's Encrypt (certbot)  — domain must point to this server" \
    "Self-signed certificate  — for local/testing use" \
    "No SSL  — HTTP only, not recommended for production")
  case "$SSL_CHOICE" in
    1) SSL_MODE="letsencrypt"; SSL_EMAIL=$(ask_input "Email for Let's Encrypt") ;;
    2) SSL_MODE="selfsigned" ;;
    3) SSL_MODE="none" ;;
  esac
fi

# Derive URL scheme from SSL choice
URL_SCHEME="http"
[[ "$SSL_MODE" == "letsencrypt" || "$SSL_MODE" == "selfsigned" ]] && URL_SCHEME="https"

PANEL_URL="${URL_SCHEME}://${PANEL_DOMAIN}"
BETTER_AUTH_URL="$PANEL_URL"
CORS_ORIGIN="$PANEL_URL"
APP_URL="$PANEL_URL"

WINGS_URL=""
$INSTALL_WINGS && WINGS_URL="${URL_SCHEME}://${WINGS_DOMAIN}"

# ── Write .env.prod ──────────────────────────────────────────────────────────
header "Writing Configuration Files"

step "Writing struxa .env.prod..."

cat > "${STRUXA_DIR}/.env.prod" << ENVFILE
# Generated by Struxa Installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Keep this file secret — it contains database passwords and signing keys.

IMAGE_TAG=${IMAGE_TAG}

MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
DATABASE_URL=${DATABASE_URL}

BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
BETTER_AUTH_URL=${BETTER_AUTH_URL}
CORS_ORIGIN=${CORS_ORIGIN}
APP_URL=${APP_URL}

JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
JWT_PUBLIC_KEY=${JWT_PUBLIC_KEY}
DATABASE_ENCRYPTION_KEY=${DATABASE_ENCRYPTION_KEY}

TURNSTILE_SECRET_KEY=${TURNSTILE_SECRET_KEY}
BOOTSTRAP_SECRET=${BOOTSTRAP_SECRET}

MINIO_ENDPOINT=http://minio:9000
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
MINIO_BUCKET=struxa
ENVFILE

chmod 600 "${STRUXA_DIR}/.env.prod"
success ".env.prod → ${STRUXA_DIR}/.env.prod"

# ── Write wings config.yml ───────────────────────────────────────────────────
if $INSTALL_WINGS; then
  step "Writing wings config.yml..."
  mkdir -p "${WINGS_DIR}/config"

  cat > "${WINGS_DIR}/config/config.yml" << WCONF
# Generated by Struxa Installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# IMPORTANT: After registering this node in the panel, paste the token values:
#   Admin → Nodes → [your node] → Configuration
#
debug: false
app_name: Pterodactyl
uuid: ""
token_id: ""
token: ""
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
    cert: ''
    key: ''
  redirects: {}
  disable_openapi_docs: false
  disable_remote_download: false
  server_remote_download_limit: 3
  remote_download_blocked_cidrs:
  - 127.0.0.0/8
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  - 169.254.0.0/16
  - ::1
  - fe80::/10
  - fc00::/7
  disable_directory_size: false
  directory_entry_limit: 10000
  send_offline_server_logs: false
  file_search_threads: 4
  file_copy_threads: 4
  file_decompression_threads: 2
  file_compression_threads: 2
  upload_limit: 100
  max_jwt_uses: 5
  trusted_proxies: []
system:
  root_directory: /var/lib/pterodactyl
  log_directory: /var/log/pterodactyl
  vmount_directory: /var/lib/pterodactyl/vmounts
  data: /var/lib/pterodactyl
  archive_directory: /var/lib/pterodactyl/archives
  backup_directory: /var/lib/pterodactyl/backups
  tmp_directory: /tmp/pterodactyl
  username: pterodactyl
  timezone: ${WINGS_TIMEZONE}
  user:
    rootless:
      enabled: false
      container_uid: 0
      container_gid: 0
    uid: ${WINGS_UID}
    gid: ${WINGS_GID}
  passwd:
    enabled: false
    directory: /run/wings/etc
  machine_id:
    enabled: true
  disk_check_concurrency: 2
  disk_check_interval: 150
  full_disk_check_every: 4
  disk_check_use_inotify: true
  disk_limiter_mode: none
  activity_send_interval: 60
  activity_send_count: 100
  check_permissions_on_boot: true
  check_permissions_on_boot_threads: 4
  websocket_log_count: 150
  sftp:
    enabled: true
    bind_address: 0.0.0.0
    bind_port: 2022
    read_only: false
    key_algorithm: ssh-ed25519
    disable_password_auth: false
    directory_entry_limit: 20000
    directory_entry_send_amount: 500
    limits:
      authentication_password_attempts: 3
      authentication_pubkey_attempts: 20
      authentication_cooldown: 60
    shell:
      enabled: true
      cli:
        name: .wings
    activity:
      log_logins: false
      log_file_reads: false
  crash_detection:
    enabled: true
    detect_clean_exit_as_crash: true
    timeout: 60
  backups:
    write_limit: 0
    read_limit: 0
    compression_level: best_speed
    mounting:
      enabled: true
      path: .backups
    wings:
      create_threads: 4
      restore_threads: 4
      archive_format: tar_gz
    s3:
      create_threads: 4
      part_upload_timeout: 7200
      retry_limit: 10
    ddup_bak:
      create_threads: 4
      compression_format: deflate
    restic:
      repository: /var/lib/pterodactyl/backups/restic
      password_file: /var/lib/pterodactyl/backups/restic_password
      retry_lock_seconds: 60
      environment: {}
    btrfs:
      restore_threads: 4
      create_read_only: true
    zfs:
      restore_threads: 4
  transfers:
    download_limit: 0
docker:
  socket: /var/run/docker.sock
  server_name_in_container_name: false
  delete_container_on_stop: true
  network:
    interface: 172.23.0.1
    disable_interface_binding: false
    dns:
    - 1.1.1.1
    - 1.0.0.1
    name: pterodactyl_nw
    ispn: false
    driver: bridge
    mode: pterodactyl_nw
    is_internal: false
    enable_icc: true
    network_mtu: 1500
    interfaces:
      v4:
        subnet: 172.23.0.0/16
        gateway: 172.23.0.1
      v6:
        subnet: fdba:17c8:6c99::/64
        gateway: fdba:17c8:6c99::1011
  domainname: ''
  registries: {}
  tmpfs_size: 100
  container_pid_limit: 5120
  installer_limits:
    timeout: 1800
    memory: 1024
    cpu: 100
  overhead:
    override: false
    default_multiplier: 1.05
    multipliers: {}
  userns_mode: ''
  log_config:
    type: local
    config:
      compress: 'false'
      max-file: '1'
      max-size: 5m
      mode: non-blocking
throttles:
  enabled: true
  lines: 2000
  line_reset_interval: 100
remote: ${PANEL_URL}
remote_headers: {}
remote_query:
  timeout: 30
  boot_servers_per_page: 50
  retry_limit: 10
allowed_mounts: []
allowed_origins: []
allow_cors_private_network: false
ignore_panel_config_updates: false
ignore_panel_wings_upgrades: false
WCONF

  mkdir -p /etc/pterodactyl
  cp "${WINGS_DIR}/config/config.yml" /etc/pterodactyl/config.yml
  chmod 600 /etc/pterodactyl/config.yml
  success "wings config.yml → ${WINGS_DIR}/config/config.yml + /etc/pterodactyl/config.yml"
fi

# ── Webserver setup ──────────────────────────────────────────────────────────
if [[ "$WS_ACTION" != "skip" ]]; then
  header "Webserver Setup"

  # Install nginx if requested
  if [[ "$WS_ACTION" == "install_nginx" ]]; then
    step "Installing nginx..."
    if command -v apt-get &>/dev/null; then
      apt-get update -qq
    fi
    pkg_install nginx
    systemctl enable --now nginx
    WEBSERVER="nginx"
    success "nginx installed"
  fi

  # ── nginx ──────────────────────────────────────────────────────────────────
  if [[ "$WEBSERVER" == "nginx" ]]; then
    step "Writing nginx configuration..."

    # Always write HTTP config first (needed for certbot HTTP challenge too)
    write_nginx_panel_http "$PANEL_DOMAIN"
    ln -sf /etc/nginx/sites-available/struxa-panel.conf \
            /etc/nginx/sites-enabled/struxa-panel.conf
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    nginx -t 2>/dev/null && systemctl reload nginx

    case "$SSL_MODE" in
      letsencrypt)
        step "Installing certbot..."
        pkg_install certbot python3-certbot-nginx

        step "Obtaining certificate for ${PANEL_DOMAIN}..."
        if certbot --nginx -d "${PANEL_DOMAIN}" \
            --non-interactive --agree-tos \
            -m "${SSL_EMAIL}" --redirect; then
          success "Certificate obtained and nginx updated by certbot"
        else
          warn "certbot failed for panel. Falling back to self-signed."
          SSL_MODE="selfsigned"
        fi

        if $INSTALL_WINGS && [[ "$WINGS_DOMAIN" != "$PANEL_DOMAIN" ]]; then
          step "Obtaining certificate for ${WINGS_DOMAIN}..."
          certbot certonly --nginx -d "${WINGS_DOMAIN}" \
            --non-interactive --agree-tos -m "${SSL_EMAIL}" || \
            warn "certbot failed for wings domain — configure SSL manually."
        fi

        if [[ "$SSL_MODE" == "letsencrypt" ]] && $INSTALL_WINGS; then
          WINGS_CERT="/etc/letsencrypt/live/${WINGS_DOMAIN}/fullchain.pem"
          WINGS_KEY="/etc/letsencrypt/live/${WINGS_DOMAIN}/privkey.pem"
          if [[ "$WINGS_DOMAIN" == "$PANEL_DOMAIN" ]]; then
            WINGS_CERT="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
            WINGS_KEY="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"
          fi
          write_nginx_wings_ssl "$WINGS_DOMAIN" "$WINGS_CERT" "$WINGS_KEY"
          ln -sf /etc/nginx/sites-available/struxa-wings.conf \
                  /etc/nginx/sites-enabled/struxa-wings.conf
          nginx -t 2>/dev/null && systemctl reload nginx
        fi
        ;;

      selfsigned)
        step "Generating self-signed certificate..."
        mkdir -p /etc/ssl/struxa
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout /etc/ssl/struxa/struxa.key \
          -out    /etc/ssl/struxa/struxa.crt \
          -subj   "/CN=${PANEL_DOMAIN}" 2>/dev/null

        write_nginx_panel_ssl "$PANEL_DOMAIN" \
          /etc/ssl/struxa/struxa.crt /etc/ssl/struxa/struxa.key

        if $INSTALL_WINGS; then
          write_nginx_wings_ssl "$WINGS_DOMAIN" \
            /etc/ssl/struxa/struxa.crt /etc/ssl/struxa/struxa.key
          ln -sf /etc/nginx/sites-available/struxa-wings.conf \
                  /etc/nginx/sites-enabled/struxa-wings.conf
        fi

        nginx -t 2>/dev/null && systemctl reload nginx
        success "Self-signed certificate configured"
        ;;

      none)
        # HTTP-only config already written and reloaded above
        if $INSTALL_WINGS; then
          # Minimal HTTP proxy for wings (non-SSL)
          cat > /etc/nginx/sites-available/struxa-wings.conf << NGXCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${WINGS_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGXCONF
          ln -sf /etc/nginx/sites-available/struxa-wings.conf \
                  /etc/nginx/sites-enabled/struxa-wings.conf
          nginx -t 2>/dev/null && systemctl reload nginx
        fi
        ;;
    esac

    if nginx -t 2>/dev/null; then
      systemctl reload nginx
      success "nginx configured and reloaded"
    else
      warn "nginx config test failed — check /etc/nginx/sites-available/struxa-panel.conf"
      nginx -t
    fi

  # ── apache ────────────────────────────────────────────────────────────────
  elif [[ "$WEBSERVER" == "apache" ]]; then
    step "Enabling required Apache modules..."
    a2enmod proxy proxy_http ssl headers rewrite 2>/dev/null || true

    APACHE_CERT=""
    APACHE_KEY=""
    APACHE_SSL="false"

    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
      pkg_install certbot python3-certbot-apache
      step "Obtaining certificate for ${PANEL_DOMAIN}..."
      if certbot --apache -d "${PANEL_DOMAIN}" \
          --non-interactive --agree-tos -m "${SSL_EMAIL}" --redirect; then
        APACHE_CERT="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
        APACHE_KEY="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"
        APACHE_SSL="true"
      else
        warn "certbot failed — falling back to self-signed."
        SSL_MODE="selfsigned"
      fi
    fi

    if [[ "$SSL_MODE" == "selfsigned" ]]; then
      step "Generating self-signed certificate..."
      mkdir -p /etc/ssl/struxa
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/struxa/struxa.key \
        -out    /etc/ssl/struxa/struxa.crt \
        -subj   "/CN=${PANEL_DOMAIN}" 2>/dev/null
      APACHE_CERT="/etc/ssl/struxa/struxa.crt"
      APACHE_KEY="/etc/ssl/struxa/struxa.key"
      APACHE_SSL="true"
    fi

    write_apache_panel "$PANEL_DOMAIN" "$APACHE_CERT" "$APACHE_KEY" "$APACHE_SSL"
    a2ensite struxa-panel 2>/dev/null || true

    if apache2ctl configtest 2>/dev/null; then
      systemctl reload apache2
      success "Apache configured and reloaded"
    else
      warn "Apache config test failed — check /etc/apache2/sites-available/struxa-panel.conf"
    fi

  # ── caddy ─────────────────────────────────────────────────────────────────
  elif [[ "$WEBSERVER" == "caddy" ]]; then
    step "Writing Caddy configuration..."
    CADDY_WINGS_DOMAIN=""
    $INSTALL_WINGS && CADDY_WINGS_DOMAIN="$WINGS_DOMAIN"
    write_caddy_blocks "$PANEL_DOMAIN" "$CADDY_WINGS_DOMAIN"
    systemctl reload caddy
    success "Caddy configured and reloaded (Caddy handles SSL automatically)"
  fi
fi

# ── Start services ───────────────────────────────────────────────────────────
header "Starting Services"

step "Pulling Struxa images..."
start_spinner "Pulling images (this may take a few minutes)..."
cd "$STRUXA_DIR"
run_logged docker compose -f docker-compose.prod.yml --env-file .env.prod pull || {
  stop_spinner; err "Failed to pull Struxa images. Check your network and image tag."
  fail_event "start_pull"; exit 1
}
stop_spinner
success "Images pulled"

step "Starting Struxa..."
start_spinner "Starting Struxa services..."
UP_LOG=$(mktemp)
if ! docker compose -f docker-compose.prod.yml --env-file .env.prod up -d > "$UP_LOG" 2>&1; then
  stop_spinner
  err "Failed to start Struxa services."
  echo "---- docker compose up output ----" >&2
  cat "$UP_LOG" >&2
  echo "---- docker compose ps ----" >&2
  docker compose -f docker-compose.prod.yml --env-file .env.prod ps >&2
  rm -f "$UP_LOG"
  fail_event "start_up"
  exit 1
fi
rm -f "$UP_LOG"
stop_spinner
success "Struxa services started"

setup_panel_admin

if $INSTALL_WINGS; then
  if $BOOTSTRAP_OK; then
    step "Writing linked wings config..."
    WINGS_CONFIG_YAML=$(echo "$BOOTSTRAP_RESPONSE" | sed -n 's/.*"configYaml":"\([^"]*\)".*/\1/p' | sed 's/\\n/\n/g')
    if [[ -n "$WINGS_CONFIG_YAML" ]]; then
      printf '%s\n' "$WINGS_CONFIG_YAML" > "${WINGS_DIR}/config/config.yml"
      mkdir -p /etc/pterodactyl
      cp "${WINGS_DIR}/config/config.yml" /etc/pterodactyl/config.yml
      chmod 600 /etc/pterodactyl/config.yml
      WINGS_LINKED=true
      success "wings config.yml written with live token"
    else
      warn "Could not extract wings config from bootstrap response — using placeholder config."
    fi
  fi

  step "Starting Wings..."
  start_spinner "Starting Wings..."
  cd "$WINGS_DIR"
  run_logged docker compose -f compose.yml up -d || {
    stop_spinner; warn "Failed to start Wings — check the config and token after panel setup."
  }
  stop_spinner
  if $WINGS_LINKED; then
    success "Wings started and linked to the panel"
  else
    success "Wings started (may need token before it connects)"
  fi
fi

cd "${SCRIPT_DIR:-/tmp}" 2>/dev/null || true

send_event "installer_completed" "\"mode\":\"$([[ $INSTALL_WINGS == true ]] && echo dashboard_wings || echo dashboard_only)\",\"webserver\":\"$WEBSERVER\",\"ssl\":\"$SSL_MODE\",\"panel_version\":\"${RESOLVED_TAG}\""

# ── Summary ──────────────────────────────────────────────────────────────────
blank
echo -e "${BOLD}${GREEN}"
echo   "  ╔══════════════════════════════════════════════════════════╗"
echo   "  ║              INSTALLATION COMPLETE                       ║"
echo   "  ╠══════════════════════════════════════════════════════════╣"
printf "  ║  Panel  :  %-46s║\n" "${PANEL_URL}"
if $INSTALL_WINGS; then
printf "  ║  Wings  :  %-46s║\n" "${WINGS_URL}"
fi
echo   "  ╠══════════════════════════════════════════════════════════╣"
printf "  ║  Struxa env  →  %-41s║\n" "${STRUXA_DIR}/.env.prod"
if $INSTALL_WINGS; then
printf "  ║  Wings cfg   →  %-41s║\n" "/etc/pterodactyl/config.yml"
fi
echo   "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

if $INSTALL_WINGS; then
  if $WINGS_LINKED; then
    echo -e "${GREEN}${BOLD}  ✓  Wings node linked to the panel automatically${RESET}"
  else
    echo -e "${YELLOW}${BOLD}  ⚠  Wings needs a token before it can connect to the panel!${RESET}"
    blank
    echo -e "  ${BOLD}Complete Wings setup:${RESET}"
    echo -e "  ${DIM}1.${RESET} Open ${PANEL_URL} and log in"
    echo -e "  ${DIM}2.${RESET} Go to  Admin → Nodes → Create New Node"
    echo -e "  ${DIM}3.${RESET} Fill in the node details and open the  Configuration  tab"
    echo -e "  ${DIM}4.${RESET} Copy  token_id  and  token  into  /etc/pterodactyl/config.yml"
    echo -e "  ${DIM}5.${RESET} Restart wings:"
    echo -e "        cd ${WINGS_DIR} && docker compose restart"
    blank
  fi
fi

echo -e "  ${BOLD}Sign in:${RESET} ${ADMIN_EMAIL}"

echo -e "  ${DIM}View logs:${RESET}"
echo -e "  ${DIM}  Struxa:${RESET}    cd ${STRUXA_DIR} && docker compose -f docker-compose.prod.yml logs -f"
if $INSTALL_WINGS; then
echo -e "  ${DIM}  Wings:${RESET}     cd ${WINGS_DIR} && docker compose logs -f"
fi
echo -e "  ${DIM}  Installer:${RESET} ${LOG_FILE}"
blank
