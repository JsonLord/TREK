#!/usr/bin/env bash
# TREK installer for NVIDIA DGX Spark (aarch64 / arm64) — Tailscale edition
# Tested on: Ubuntu 22.04+ / Linux 6.17.0-1021-nvidia aarch64
#
# Access method: Tailscale serve (automatic HTTPS via Tailscale certs)
#   - TREK listens on localhost:3000 (not exposed to LAN)
#   - tailscale serve terminates TLS → proxies to localhost:3000
#   - You reach TREK at https://<machine>.ts.net (full HTTPS, no cert work)
#   - COOKIE_SECURE stays true → no "Access token required" ever
#
# Usage:
#   chmod +x install-dgx.sh
#   ./install-dgx.sh
#
# Customise via environment variables before running:
#   TREK_PORT        (default 3000  — only used on localhost, not exposed)
#   TREK_DIR         (default ~/trek)
#   ADMIN_EMAIL      (default admin@trek.local)
#   ADMIN_PASSWORD   (default: random 16-char, printed once)
#   TZ               (default: auto-detected from /etc/timezone)

set -euo pipefail

###############################################################################
# Helpers
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[trek]${NC} $*"; }
success() { echo -e "${GREEN}[trek]${NC} $*"; }
warn()    { echo -e "${YELLOW}[trek]${NC} $*"; }
error()   { echo -e "${RED}[trek]${NC} $*" >&2; exit 1; }

###############################################################################
# 1. Preflight checks
###############################################################################
info "=== TREK DGX Spark installer (Tailscale edition) ==="

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  warn "Expected aarch64/arm64, got: $ARCH — proceeding anyway."
fi
info "Architecture: $ARCH"

# Docker
if ! command -v docker &>/dev/null; then
  error "Docker not found. Install Docker Engine (arm64):\n  https://docs.docker.com/engine/install/ubuntu/"
fi
info "Docker: $(docker --version)"
if ! docker info &>/dev/null; then
  error "Docker daemon is not running.\n  sudo systemctl start docker"
fi

# Docker Compose
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  error "Docker Compose not found.\n  sudo apt-get install docker-compose-plugin"
fi
info "Compose: $COMPOSE"

# Tailscale
if ! command -v tailscale &>/dev/null; then
  error "Tailscale not found. Install it:\n  curl -fsSL https://tailscale.com/install.sh | sh\n  sudo tailscale up"
fi
if ! tailscale status &>/dev/null; then
  error "Tailscale is not connected. Run:\n  sudo tailscale up"
fi
info "Tailscale: $(tailscale version | head -1)"

###############################################################################
# 2. Detect Tailscale hostname
###############################################################################
# tailscale status --json gives the MagicDNS FQDN (e.g. mymachine.tail1234.ts.net)
TS_HOSTNAME=$(tailscale status --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Self']['DNSName'].rstrip('.'))" \
  2>/dev/null || true)

if [[ -z "$TS_HOSTNAME" ]]; then
  # Fallback: use the Tailscale IP
  TS_HOSTNAME=$(tailscale ip -4 2>/dev/null | head -1 || true)
  TS_URL="http://${TS_HOSTNAME}:${TREK_PORT:-3000}"
  TAILSCALE_HTTPS=false
  warn "Could not determine MagicDNS hostname — falling back to Tailscale IP: $TS_HOSTNAME"
  warn "HTTPS via tailscale serve won't be configured. Set COOKIE_SECURE=false is needed."
else
  TS_URL="https://${TS_HOSTNAME}"
  TAILSCALE_HTTPS=true
  info "Tailscale hostname: $TS_HOSTNAME"
  info "App URL will be  : $TS_URL"
fi

###############################################################################
# 3. Configuration
###############################################################################
TREK_PORT="${TREK_PORT:-3001}"
TREK_DIR="${TREK_DIR:-$HOME/trek}"

if [[ -z "${TZ:-}" ]]; then
  TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@trek.local}"
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 16 || true)
  GENERATED_PASSWORD=true
else
  GENERATED_PASSWORD=false
fi

ENCRYPTION_KEY=$(openssl rand -hex 32)

info "Install directory : $TREK_DIR"
info "Internal port     : $TREK_PORT  (localhost only)"
info "Timezone          : $TZ"
info "Admin email       : $ADMIN_EMAIL"

###############################################################################
# 4. Create directory structure
###############################################################################
info "Creating data directories..."
mkdir -p "$TREK_DIR/data" "$TREK_DIR/uploads"

###############################################################################
# 5. Write docker-compose.yml
###############################################################################
info "Writing docker-compose.yml..."

if [[ "$TAILSCALE_HTTPS" == "true" ]]; then
  # Bind only to localhost — Tailscale serve proxies in from outside.
  # Full HTTPS: COOKIE_SECURE can be true, FORCE_HTTPS off (TS handles it),
  # TRUST_PROXY=1 so Express reads X-Forwarded-For/Proto from tailscaled.
  COOKIE_SECURE_VAL="true"
  FORCE_HTTPS_VAL="false"
  PORT_BINDING="127.0.0.1:${TREK_PORT}:3000"
  APP_URL_LINE="APP_URL: \"${TS_URL}\""
  COOKIE_SECURE_COMMENT="# HTTPS via tailscale serve — Secure cookie is safe"
else
  COOKIE_SECURE_VAL="false"
  FORCE_HTTPS_VAL="false"
  PORT_BINDING="${TREK_PORT}:3000"
  APP_URL_LINE="# APP_URL: \"${TS_URL}\""
  COOKIE_SECURE_COMMENT="# No HTTPS detected — Secure flag disabled to prevent AUTH_REQUIRED"
fi

cat > "$TREK_DIR/docker-compose.yml" <<EOF
services:
  trek:
    image: mauriceboe/trek:latest
    # Multi-arch manifest: Docker on aarch64 pulls the linux/arm64 layer.
    platform: linux/arm64
    container_name: trek
    restart: unless-stopped
    ports:
      - "${PORT_BINDING}"
    volumes:
      - ./data:/app/data
      - ./uploads:/app/uploads
    environment:
      # ── Security ──────────────────────────────────────────────────────────
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"

      ${COOKIE_SECURE_COMMENT}
      COOKIE_SECURE: "${COOKIE_SECURE_VAL}"

      # tailscale serve terminates TLS and forwards X-Forwarded-Proto: https.
      # TRUST_PROXY=1 tells Express to trust that header for rate limiting
      # and audit logs. FORCE_HTTPS is off because tailscaled enforces HTTPS
      # before the request ever reaches the container.
      TRUST_PROXY: "1"
      FORCE_HTTPS: "${FORCE_HTTPS_VAL}"

      # ── Public URL (required for MCP OAuth, OIDC, email links) ────────────
      ${APP_URL_LINE}

      # ── First-boot admin account (used only on the very first start) ──────
      ADMIN_EMAIL: "${ADMIN_EMAIL}"
      ADMIN_PASSWORD: "${ADMIN_PASSWORD}"

      # ── General ───────────────────────────────────────────────────────────
      TZ: "${TZ}"
      NODE_ENV: "production"
      LOG_LEVEL: "info"

      # ── Optional integrations (uncomment to enable) ───────────────────────
      # OPENWEATHER_API_KEY: ""
      # GOOGLE_PLACES_API_KEY: ""
      # SMTP_HOST: ""
      # SMTP_PORT: "587"
      # SMTP_USER: ""
      # SMTP_PASS: ""
      # SMTP_FROM: ""
      # SMTP_SECURE: "false"

    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    tmpfs:
      - /tmp:noexec,nosuid,size=128m
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
EOF

success "docker-compose.yml written."

###############################################################################
# 6. Save credentials (mode 600)
###############################################################################
CREDS_FILE="$TREK_DIR/.trek-credentials"
cat > "$CREDS_FILE" <<EOF
# TREK credentials — do not commit this file
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
TAILSCALE_URL=${TS_URL}
EOF
chmod 600 "$CREDS_FILE"
info "Credentials saved to $CREDS_FILE"

###############################################################################
# 7. Configure tailscale serve (HTTPS → localhost:TREK_PORT)
###############################################################################
if [[ "$TAILSCALE_HTTPS" == "true" ]]; then
  info "Configuring tailscale serve (https → localhost:${TREK_PORT})..."

  # Remove any existing rule on port 443 for a clean slate
  tailscale serve https:443 off 2>/dev/null || true

  # Proxy all HTTPS traffic on the Tailscale interface to localhost:TREK_PORT.
  # tailscaled handles cert issuance/renewal automatically via LetsEncrypt.
  sudo tailscale serve --https=443 --set-path=/ "http://localhost:${TREK_PORT}"

  # Persist the serve config so it survives reboots
  # (tailscale serve state is stored in /var/lib/tailscale/ automatically)

  success "tailscale serve configured: https://${TS_HOSTNAME} → localhost:${TREK_PORT}"
fi

###############################################################################
# 8. Kill any Docker containers already using port TREK_PORT
###############################################################################
info "Checking for containers on port ${TREK_PORT}..."
BLOCKING=$(docker ps --format '{{.ID}} {{.Ports}}' \
  | grep -E "(0\.0\.0\.0|127\.0\.0\.1|::):${TREK_PORT}->" \
  | awk '{print $1}' || true)

if [[ -n "$BLOCKING" ]]; then
  warn "Stopping containers using port ${TREK_PORT}: $BLOCKING"
  docker rm -f $BLOCKING
  success "Cleared."
else
  info "Port ${TREK_PORT} is free."
fi

###############################################################################
# 9. Pull image
###############################################################################
info "Pulling Docker image (arm64)..."
docker pull --platform linux/arm64 mauriceboe/trek:latest

###############################################################################
# 10. Start TREK
###############################################################################
info "Starting TREK..."
cd "$TREK_DIR"
$COMPOSE up -d

###############################################################################
# 11. Wait for healthy
###############################################################################
info "Waiting for TREK to become healthy (up to 90 s)..."
HEALTHY=false
for i in $(seq 1 18); do
  STATUS=$(docker inspect trek --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  if [[ "$STATUS" == "healthy" ]]; then
    HEALTHY=true; break
  fi
  echo -n "."; sleep 5
done
echo ""

if [[ "$HEALTHY" == "true" ]]; then
  success "TREK is healthy!"
else
  warn "Health check timed out. Check logs:  docker logs trek"
fi

###############################################################################
# 12. Summary
###############################################################################
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  TREK is running!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  URL (Tailscale) : ${CYAN}${TS_URL}${NC}"
echo -e "  Admin email     : ${CYAN}${ADMIN_EMAIL}${NC}"
if [[ "$GENERATED_PASSWORD" == "true" ]]; then
echo -e "  Admin password  : ${YELLOW}${ADMIN_PASSWORD}${NC}  ← SAVE THIS"
fi
echo ""
echo -e "  Credentials file: ${TREK_DIR}/.trek-credentials"
echo -e "  Compose file    : ${TREK_DIR}/docker-compose.yml"
echo ""
echo "  Useful commands:"
echo "    docker logs -f trek                                    # live logs"
echo "    cd $TREK_DIR && $COMPOSE down                         # stop"
echo "    cd $TREK_DIR && $COMPOSE pull && $COMPOSE up -d       # update"
echo "    tailscale serve status                                 # verify proxy"
echo ""
if [[ "$TAILSCALE_HTTPS" == "true" ]]; then
echo -e "${GREEN}  HTTPS is active via tailscale serve.${NC}"
echo -e "${GREEN}  Session cookies are fully secure — no workarounds needed.${NC}"
else
echo -e "${YELLOW}  MagicDNS not detected — running over plain Tailscale IP.${NC}"
echo -e "${YELLOW}  COOKIE_SECURE=false is set to prevent AUTH_REQUIRED errors.${NC}"
echo -e "${YELLOW}  Enable MagicDNS in the Tailscale admin console to get HTTPS.${NC}"
fi
echo ""
