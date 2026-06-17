#!/usr/bin/env bash
# TREK installer for NVIDIA DGX Spark (aarch64 / arm64)
# Tested on: Ubuntu 22.04+ / Linux 6.17.0-1021-nvidia aarch64
#
# Usage:
#   chmod +x install-dgx.sh
#   ./install-dgx.sh
#
# To customise before running, export any of these variables:
#   TREK_PORT        (default 3000)
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
info "=== TREK DGX Spark installer ==="

# Architecture check
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  warn "Expected aarch64/arm64 but got: $ARCH — proceeding anyway."
fi
info "Architecture: $ARCH"

# Docker check
if ! command -v docker &>/dev/null; then
  error "Docker not found. Install Docker Engine (arm64) first:\n  https://docs.docker.com/engine/install/ubuntu/"
fi
DOCKER_VERSION=$(docker --version)
info "Docker: $DOCKER_VERSION"

# Docker daemon running?
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start it with:\n  sudo systemctl start docker"
fi

# Docker Compose: prefer the 'docker compose' plugin, fall back to standalone
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  error "Docker Compose not found.\n  Install via: sudo apt-get install docker-compose-plugin\n  or: sudo apt-get install docker-compose"
fi
info "Compose command: $COMPOSE"

###############################################################################
# 2. Configuration
###############################################################################
TREK_PORT="${TREK_PORT:-3000}"
TREK_DIR="${TREK_DIR:-$HOME/trek}"

# Timezone — auto-detect from /etc/timezone, fall back to UTC
if [[ -z "${TZ:-}" ]]; then
  if [[ -f /etc/timezone ]]; then
    TZ=$(cat /etc/timezone)
  else
    TZ="UTC"
  fi
fi

# Admin credentials
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@trek.local}"
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  # Generate a random 16-char password (no ambiguous chars)
  ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 16 || true)
  GENERATED_PASSWORD=true
else
  GENERATED_PASSWORD=false
fi

# Encryption key — 32 random bytes as hex (64 hex chars)
ENCRYPTION_KEY=$(openssl rand -hex 32)

info "Install directory : $TREK_DIR"
info "Port              : $TREK_PORT"
info "Timezone          : $TZ"
info "Admin email       : $ADMIN_EMAIL"

###############################################################################
# 3. Create directory structure
###############################################################################
info "Creating data directories..."
mkdir -p "$TREK_DIR/data"
mkdir -p "$TREK_DIR/uploads"

###############################################################################
# 4. Write docker-compose.yml
###############################################################################
info "Writing docker-compose.yml..."
cat > "$TREK_DIR/docker-compose.yml" <<EOF
services:
  trek:
    image: mauriceboe/trek:latest
    # mauriceboe/trek is a multi-arch manifest (linux/amd64 + linux/arm64).
    # Docker on aarch64 automatically pulls the arm64 layer.
    platform: linux/arm64
    container_name: trek
    restart: unless-stopped
    ports:
      - "${TREK_PORT}:3000"
    volumes:
      - ./data:/app/data
      - ./uploads:/app/uploads
    environment:
      # ── Security ──────────────────────────────────────────────────────────
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"

      # COOKIE_SECURE=false is REQUIRED when accessing TREK over plain HTTP
      # (no TLS / no reverse proxy). Without this the browser drops the session
      # cookie and every authenticated request returns "Access token required".
      # Change to 'true' (or remove) once you add HTTPS / a reverse proxy.
      COOKIE_SECURE: "false"

      # ── First-boot admin account (only used on the very first start) ──────
      ADMIN_EMAIL: "${ADMIN_EMAIL}"
      ADMIN_PASSWORD: "${ADMIN_PASSWORD}"

      # ── General ───────────────────────────────────────────────────────────
      TZ: "${TZ}"
      NODE_ENV: "production"
      LOG_LEVEL: "info"

      # APP_URL is optional for plain LAN access but required if you later
      # enable OIDC or the MCP integration. Set it to the URL you use in
      # your browser, e.g.:
      #   APP_URL: "http://192.168.1.x:${TREK_PORT}"
      # APP_URL: ""

      # ── Optional integrations (uncomment to enable) ───────────────────────
      # OPENWEATHER_API_KEY: ""
      # GOOGLE_PLACES_API_KEY: ""
      # SMTP_HOST: ""
      # SMTP_PORT: "587"
      # SMTP_USER: ""
      # SMTP_PASS: ""
      # SMTP_FROM: ""
      # SMTP_SECURE: "false"

    # Minimal capability set — gosu handles the root→node drop internally
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    # /tmp is writable but non-executable
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
# 5. Save credentials to a local file (chmod 600)
###############################################################################
CREDS_FILE="$TREK_DIR/.trek-credentials"
cat > "$CREDS_FILE" <<EOF
# TREK credentials — keep this file safe, do not commit it
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
EOF
chmod 600 "$CREDS_FILE"
info "Credentials saved to $CREDS_FILE (mode 600)"

###############################################################################
# 6. Pull image
###############################################################################
info "Pulling Docker image (arm64)..."
docker pull --platform linux/arm64 mauriceboe/trek:latest

###############################################################################
# 7. Start the container
###############################################################################
info "Starting TREK..."
cd "$TREK_DIR"
$COMPOSE up -d

###############################################################################
# 8. Wait for health check
###############################################################################
info "Waiting for TREK to become healthy (up to 90 s)..."
HEALTHY=false
for i in $(seq 1 18); do
  STATUS=$(docker inspect trek --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  if [[ "$STATUS" == "healthy" ]]; then
    HEALTHY=true
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

if [[ "$HEALTHY" == "true" ]]; then
  success "TREK is healthy!"
else
  warn "Health check did not pass within 90 s. Check logs:"
  warn "  docker logs trek"
fi

###############################################################################
# 9. Summary
###############################################################################
HOST_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "<your-ip>")

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  TREK is running!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  URL          : ${CYAN}http://${HOST_IP}:${TREK_PORT}${NC}"
echo -e "  Admin email  : ${CYAN}${ADMIN_EMAIL}${NC}"
if [[ "$GENERATED_PASSWORD" == "true" ]]; then
echo -e "  Admin pass   : ${YELLOW}${ADMIN_PASSWORD}${NC}  ← SAVE THIS"
fi
echo ""
echo -e "  Credentials  : ${TREK_DIR}/.trek-credentials"
echo -e "  Compose file : ${TREK_DIR}/docker-compose.yml"
echo ""
echo "  Useful commands:"
echo "    docker logs -f trek           # live logs"
echo "    cd $TREK_DIR && $COMPOSE down  # stop"
echo "    cd $TREK_DIR && $COMPOSE pull && $COMPOSE up -d  # update"
echo ""
echo -e "${YELLOW}  NOTE: COOKIE_SECURE=false is set so the session cookie${NC}"
echo -e "${YELLOW}  works over plain HTTP. If you add HTTPS later, remove${NC}"
echo -e "${YELLOW}  that env var (or set it to true) and restart.${NC}"
echo ""
