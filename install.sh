#!/usr/bin/env bash
# Struxa Installer — sets up Struxa dashboard and optionally Wings node agent

# Redirect stdin from the terminal so interactive prompts work when the script
# is fetched via curl (curl | bash pipes stdin; bash <(curl) does not).
exec < /dev/tty

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
  blank
}

# ── Root check ───────────────────────────────────────────────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Try: sudo bash install.sh"
    exit 1
  fi
}

# ── Input helpers ────────────────────────────────────────────────────────────
ask_yn() {
  local prompt="$1" default="${2:-y}" reply
  local hint; [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  while true; do
    echo -en "${BOLD}  ? ${RESET}${prompt} ${DIM}${hint}${RESET} " >/dev/tty
    read -r reply </dev/tty
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo -e "${YELLOW}  ⚠${RESET} Please answer y or n." >/dev/tty ;;
    esac
  done
}

# All display in ask_input/ask_secret/ask_select goes to /dev/tty so that
# calling them inside $() command substitution doesn't swallow the prompts.
ask_input() {
  local prompt="$1" default="${2:-}" result
  if [[ -n "$default" ]]; then
    echo -en "${BOLD}  ? ${RESET}${prompt} ${DIM}[${default}]${RESET}: " >/dev/tty
  else
    echo -en "${BOLD}  ? ${RESET}${prompt}: " >/dev/tty
  fi
  read -r result </dev/tty
  echo "${result:-$default}"
}

ask_secret() {
  local prompt="$1" result
  echo -en "${BOLD}  ? ${RESET}${prompt} ${DIM}(hidden)${RESET}: " >/dev/tty
  read -rs result </dev/tty
  echo "" >/dev/tty
  echo "$result"
}

ask_select() {
  local prompt="$1"; shift
  local options=("$@") choice i=1
  echo -e "${BOLD}  ? ${RESET}${prompt}" >/dev/tty
  for opt in "${options[@]}"; do
    echo -e "     ${CYAN}[${i}]${RESET} ${opt}" >/dev/tty
    (( i++ )) || true
  done
  while true; do
    echo -en "  ${BOLD}→${RESET} Choice: " >/dev/tty
    read -r choice </dev/tty
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "$choice"
      return
    fi
    echo -e "${YELLOW}  ⚠${RESET} Enter a number between 1 and ${#options[@]}." >/dev/tty
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

# Clean up spinner on exit
trap 'stop_spinner' EXIT

# ── Argument parsing ─────────────────────────────────────────────────────────
USE_NIGHTLY=false
MODE="install"
for arg in "$@"; do
  case "$arg" in
    --nightly) USE_NIGHTLY=true ;;
    update)    MODE="update" ;;
  esac
done

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

# ── Update existing installation ─────────────────────────────────────────────
do_update() {
  header "Update Struxa"

  if [[ ! -f "${STRUXA_DIR}/.env.prod" ]]; then
    err "No existing installation found at ${STRUXA_DIR}/.env.prod"
    err "Run the installer without the update option first."
    exit 1
  fi

  local new_tag="latest"
  $USE_NIGHTLY && new_tag="nightly"

  local current_tag
  current_tag=$(grep '^IMAGE_TAG=' "${STRUXA_DIR}/.env.prod" | cut -d= -f2)

  blank
  info "Current image tag : ${BOLD}${current_tag}${RESET}"
  info "Will update to    : ${BOLD}${new_tag}${RESET}"
  blank
  warn "This will pull new images and restart all Struxa services."
  blank

  if ! ask_yn "Proceed with update?" "y"; then
    info "Update cancelled."
    exit 0
  fi

  blank
  step "Setting IMAGE_TAG=${new_tag}..."
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${new_tag}/" "${STRUXA_DIR}/.env.prod"
  success "IMAGE_TAG → ${new_tag}"

  step "Fetching latest docker-compose.prod.yml..."
  curl -fsSL "https://raw.githubusercontent.com/struxadotcloud/struxa/master/docker-compose.prod.yml" \
    -o "${STRUXA_DIR}/docker-compose.prod.yml" || warn "Failed to fetch latest compose file — using existing."

  step "Pulling Struxa images..."
  start_spinner "Pulling images (this may take a few minutes)..."
  cd "$STRUXA_DIR"
  docker compose -f docker-compose.prod.yml --env-file .env.prod pull > /dev/null 2>&1 || {
    stop_spinner; err "Failed to pull images. Check your network connection."; exit 1
  }
  stop_spinner
  success "Images pulled"

  step "Restarting Struxa services..."
  start_spinner "Restarting services..."
  docker compose -f docker-compose.prod.yml --env-file .env.prod up -d > /dev/null 2>&1 || {
    stop_spinner; err "Failed to restart Struxa services."; exit 1
  }
  stop_spinner
  success "Struxa services updated and restarted"

  if [[ -f "${WINGS_DIR}/compose.yml" ]]; then
    header "Update Wings"
    blank
    warn "This will pull new Wings images and restart the Wings node agent."
    blank
    if ask_yn "Proceed with Wings update?" "y"; then
      step "Pulling Wings images..."
      start_spinner "Pulling Wings images..."
      cd "$WINGS_DIR"
      docker compose -f compose.yml pull > /dev/null 2>&1 || {
        stop_spinner; warn "Failed to pull Wings images — check manually."
      }
      stop_spinner

      step "Restarting Wings..."
      start_spinner "Restarting Wings..."
      docker compose -f compose.yml up -d > /dev/null 2>&1 || {
        stop_spinner; warn "Failed to restart Wings — check manually."
      }
      stop_spinner
      success "Wings updated and restarted"
    else
      info "Wings update skipped."
    fi
  fi

  blank
  success "Update complete"
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

STRUXA_DIR="/opt/struxa"
WINGS_DIR="/opt/wings"

show_banner
require_root
check_prereqs

[[ "$MODE" == "update" ]] && do_update

# ── Installation mode ────────────────────────────────────────────────────────
header "Installation Mode"
INSTALL_MODE=$(ask_select "What would you like to install?" \
  "Dashboard only  (Struxa panel + database)" \
  "Dashboard + Wings  (panel, database and node agent)")

INSTALL_WINGS=false
[[ "$INSTALL_MODE" == "2" ]] && INSTALL_WINGS=true

# ── Create install directories & write compose files ────────────────────────
header "Preparing Install Directories"

step "Creating ${STRUXA_DIR}..."
mkdir -p "$STRUXA_DIR"

step "Fetching docker-compose.prod.yml..."
curl -fsSL "https://raw.githubusercontent.com/struxadotcloud/struxa/master/docker-compose.prod.yml" \
  -o "${STRUXA_DIR}/docker-compose.prod.yml" || {
  err "Failed to download Struxa compose file."
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
    exit 1
  }
  success "Wings compose file ready"
fi

# ── Dashboard configuration ──────────────────────────────────────────────────
header "Dashboard Configuration"

PANEL_DOMAIN=$(ask_input "Panel domain" "panel.example.com")

blank
step "Generating secure credentials..."

MYSQL_ROOT_PASSWORD=$(generate_secret)
MYSQL_DATABASE="struxa"
MYSQL_USER="struxa"
MYSQL_PASSWORD=$(generate_secret)
BETTER_AUTH_SECRET=$(generate_secret)
DATABASE_ENCRYPTION_KEY=$(generate_hex64)

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
IMAGE_TAG="latest"
$USE_NIGHTLY && IMAGE_TAG="nightly"

success "Dashboard configuration ready"

# ── Wings configuration ──────────────────────────────────────────────────────
WINGS_DOMAIN=""
WINGS_TIMEZONE="UTC"
WINGS_UID="988"
WINGS_GID="988"

if $INSTALL_WINGS; then
  header "Wings Configuration"
  WINGS_DOMAIN=$(ask_input "Wings node domain or IP" "node.example.com")
  WINGS_TIMEZONE=$(ask_input "Timezone" "UTC")
  WINGS_UID=$(ask_input "Wings user UID" "988")
  WINGS_GID=$(ask_input "Wings user GID" "988")
  success "Wings configuration ready"
fi

# ── Webserver configuration ──────────────────────────────────────────────────
header "Webserver Configuration"

DETECTED_WS=$(detect_webserver)
WS_ACTION="skip"
SSL_MODE="none"
SSL_EMAIL=""
WEBSERVER="none"

if [[ "$DETECTED_WS" != "none" ]]; then
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

if [[ "$WS_ACTION" != "skip" ]]; then
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
docker compose -f docker-compose.prod.yml --env-file .env.prod pull > /dev/null 2>&1 || {
  stop_spinner; err "Failed to pull Struxa images. Check your network and image tag."; exit 1
}
stop_spinner
success "Images pulled"

step "Starting Struxa..."
start_spinner "Starting Struxa services..."
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d > /dev/null 2>&1 || {
  stop_spinner; err "Failed to start Struxa services."; exit 1
}
stop_spinner
success "Struxa services started"

if $INSTALL_WINGS; then
  step "Starting Wings..."
  start_spinner "Starting Wings..."
  cd "$WINGS_DIR"
  docker compose -f compose.yml up -d > /dev/null 2>&1 || {
    stop_spinner; warn "Failed to start Wings — check the config and token after panel setup."
  }
  stop_spinner
  success "Wings started (may need token before it connects)"
fi

cd "$SCRIPT_DIR"

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

echo -e "  ${DIM}View logs:${RESET}"
echo -e "  ${DIM}  Struxa:${RESET}  cd ${STRUXA_DIR} && docker compose -f docker-compose.prod.yml logs -f"
if $INSTALL_WINGS; then
echo -e "  ${DIM}  Wings:${RESET}   cd ${WINGS_DIR} && docker compose logs -f"
fi
blank
