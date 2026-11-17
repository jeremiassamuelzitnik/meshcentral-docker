#!/usr/bin/env bash
# =============================================================================
# install_meshcentral.sh — MeshCentral + MongoDB/MySQL + Watchtower in Docker
# Debian / Ubuntu / Raspberry Pi OS (64-bit) · Pi 3/4/5, WSL2, x86_64 w/o AVX
#
# Usage:
#   sudo bash install_meshcentral.sh
#
# Optional variables (non-interactive mode / overrides):
#   DB_ENGINE=mongo|mysql        Skip the database question
#   MESH_DOMAIN=mesh.example.com Public domain behind the reverse proxy
#                                (set it empty, MESH_DOMAIN="", for local only)
#   MONGO_VERSION=4.0            Force a MongoDB image version
#   MYSQL_IMAGE=mysql:8.0        MySQL image (8.0 needed for the auth flag below)
#   TZ_NAME=America/Argentina/Buenos_Aires   Watchtower time zone
#
#   e.g.: sudo DB_ENGINE=mysql MESH_DOMAIN=mesh.example.com bash install_meshcentral.sh
# =============================================================================
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }
line()  { echo -e "${YELLOW}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Variables ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/meshcentral"
DATA_DIR="${INSTALL_DIR}/data"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
CONFIG_FILE="${DATA_DIR}/config.json"
ENV_FILE="${INSTALL_DIR}/.env"
PROJECT_NAME="meshcentral"          # = name of INSTALL_DIR → volume prefix
HOST_BIND="127.0.0.1"
HOST_PORT=8010
TZ_NAME="${TZ_NAME:-America/Argentina/Buenos_Aires}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
TRUSTED_PROXY="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# Filled in at runtime
DB_ENGINE="${DB_ENGINE:-}"
DB_SERVICE=""; DB_CONTAINER=""; DB_VOLUME=""
MYSQL_ROOT_PASSWORD=""; MYSQL_DATABASE="meshcentral"; MYSQL_USER="meshcentral"; MYSQL_PASSWORD=""

# =============================================================================
# Helpers
# =============================================================================

# Ask a question on the terminal (works with "curl ... | sudo bash" too).
# $1 = prompt, $2 = default. Prints the answer on stdout.
ask() {
  local reply=""
  if { : </dev/tty; } 2>/dev/null; then
    read -r -p "$1" reply </dev/tty || true
  fi
  echo "${reply:-$2}"
}

# Random hex secret (safe inside JSON, YAML and .env without escaping)
gen_secret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Read KEY from the .env file (empty if missing)
env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

# =============================================================================
# FUNCTION: Ask which database engine to use
# =============================================================================
choose_db_engine() {
  if [[ -z "$DB_ENGINE" ]]; then
    {
      echo
      echo -e "${BOLD}Which database should MeshCentral use?${RESET}"
      echo "  1) MongoDB  (recommended, most tested with MeshCentral)"
      echo "  2) MySQL"
    } >&2
    while true; do
      DB_ENGINE=$(ask "Choose [1/2] (default 1): " "1")
      case "${DB_ENGINE,,}" in
        1|mongo|mongodb) DB_ENGINE="mongo"; break ;;
        2|mysql)         DB_ENGINE="mysql"; break ;;
        *) warn "Invalid option: ${DB_ENGINE}" ;;
      esac
    done
  fi

  case "${DB_ENGINE,,}" in
    mongo|mongodb)
      DB_ENGINE="mongo"; DB_SERVICE="mongodb"; DB_CONTAINER="meshcentral-mongo"; DB_VOLUME="mongo_data" ;;
    mysql)
      DB_ENGINE="mysql"; DB_SERVICE="mysql";   DB_CONTAINER="meshcentral-mysql"; DB_VOLUME="mysql_data" ;;
    *) die "Invalid DB_ENGINE='${DB_ENGINE}'. Use 'mongo' or 'mysql'." ;;
  esac
  ok "Database engine: ${DB_ENGINE}"
}

# =============================================================================
# FUNCTION: Ask for the public domain (reverse proxy) — optional
# =============================================================================
choose_domain() {
  if [[ -z "${MESH_DOMAIN+x}" ]]; then
    local current=""
    if [[ -f "$CONFIG_FILE" ]]; then
      current=$(sed -n 's/.*"cert"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1 || true)
    fi
    echo >&2
    MESH_DOMAIN=$(ask "Public domain behind your reverse proxy (e.g. mesh.example.com)${current:+ [${current}]} (empty = local only): " "$current")
  fi

  MESH_DOMAIN="${MESH_DOMAIN,,}"
  MESH_DOMAIN="${MESH_DOMAIN#http://}"; MESH_DOMAIN="${MESH_DOMAIN#https://}"; MESH_DOMAIN="${MESH_DOMAIN%%/*}"

  if [[ -n "$MESH_DOMAIN" ]]; then
    [[ "$MESH_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || die "Invalid domain: '${MESH_DOMAIN}'"
    ok "Public domain: ${MESH_DOMAIN}"
  else
    ok "No public domain: local access only (https://localhost:${HOST_PORT})"
  fi
}

# =============================================================================
# FUNCTION: Detect compatible MongoDB version based on CPU architecture & flags
# =============================================================================
detect_mongo_version() {
  if [[ -n "${MONGO_VERSION:-}" ]]; then
    ok "MONGO_VERSION forced by user → MongoDB ${MONGO_VERSION}"
    echo "$MONGO_VERSION"; return
  fi

  info "Detecting CPU architecture and compatibility flags..."
  local arch; arch=$(uname -m)

  if [[ "$arch" == "x86_64" ]]; then
    if grep -qw avx /proc/cpuinfo 2>/dev/null; then
      ok "AVX detected (x86_64) → using MongoDB 7.0"
      echo "7.0"
    else
      warn "AVX NOT detected (x86_64) → using MongoDB 4.4"
      echo "4.4"
    fi
  else # aarch64 (checked earlier)
    if grep -qw atomics /proc/cpuinfo 2>/dev/null; then
      ok "LSE/atomics detected (ARMv8.2+, e.g. Pi 5) → using MongoDB 7.0"
      echo "7.0"
    else
      warn "LSE NOT detected (ARMv8.0, e.g. Pi 3/4) → using MongoDB 4.0 to avoid SIGILL"
      echo "4.0"
    fi
  fi
}

# =============================================================================
# FUNCTION: Load or create MySQL credentials (.env)
# =============================================================================
prepare_mysql_env() {
  MYSQL_ROOT_PASSWORD=$(env_get MYSQL_ROOT_PASSWORD)
  MYSQL_PASSWORD=$(env_get MYSQL_PASSWORD)

  if [[ -n "$MYSQL_ROOT_PASSWORD" && -n "$MYSQL_PASSWORD" ]]; then
    ok "Reusing existing MySQL credentials from ${ENV_FILE}"
  else
    if docker volume inspect "${PROJECT_NAME}_${DB_VOLUME}" &>/dev/null; then
      warn "Volume ${PROJECT_NAME}_${DB_VOLUME} already exists but ${ENV_FILE} has no credentials."
      warn "New passwords will NOT match the existing database. If it fails, remove the volume:"
      warn "  docker volume rm ${PROJECT_NAME}_${DB_VOLUME}   (this deletes the MySQL data)"
    fi
    MYSQL_ROOT_PASSWORD=$(gen_secret)
    MYSQL_PASSWORD=$(gen_secret)
    ok "Generated new MySQL credentials"
  fi

  umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by install_meshcentral.sh — keep this file private.
# Changing these values does NOT change the passwords of an existing database.
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
EOF
  umask 022
  chmod 600 "$ENV_FILE"
}

# =============================================================================
# FUNCTION: docker-compose.yml generation
# =============================================================================
compose_db_service() {
  if [[ "$DB_ENGINE" == "mongo" ]]; then
    cat <<EOF
  mongodb:
    image: mongo:${MONGO_VERSION}
    container_name: meshcentral-mongo
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - mongo_data:/data/db
    networks:
      - mesh_net
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "mongo --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null || mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null"
        ]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 120s
EOF
  else
    cat <<EOF
  mysql:
    image: ${MYSQL_IMAGE}
    container_name: meshcentral-mysql
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command: ["--default-authentication-plugin=mysql_native_password"]
    env_file:
      - .env
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - mesh_net
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "MYSQL_PWD=\$\$MYSQL_ROOT_PASSWORD mysqladmin ping -h 127.0.0.1 -u root --silent"
        ]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 120s
EOF
  fi
}

write_compose() {
  info "Generating docker-compose.yml (${DB_SERVICE}: $( [[ $DB_ENGINE == mongo ]] && echo "mongo:${MONGO_VERSION}" || echo "$MYSQL_IMAGE" ))..."
  {
    echo "services:"
    compose_db_service
    cat <<EOF

  meshcentral:
    image: ghcr.io/ylianst/meshcentral:latest
    container_name: meshcentral-app
    restart: unless-stopped
    ports:
      - "${HOST_BIND}:${HOST_PORT}:443"
    volumes:
      - ./data:/opt/meshcentral/meshcentral-data
      - ./files:/opt/meshcentral/meshcentral-files
      - ./backup:/opt/meshcentral/meshcentral-backups
      - ./web:/opt/meshcentral/meshcentral-web
    networks:
      - mesh_net
    depends_on:
      ${DB_SERVICE}:
        condition: service_healthy
    environment:
      NODE_ENV: production
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  watchtower:
    image: nickfedor/watchtower:latest
    container_name: meshcentral-watchtower
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      TZ: ${TZ_NAME}
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_ROLLING_RESTART: "true"

networks:
  mesh_net:
    driver: bridge

volumes:
  ${DB_VOLUME}:
EOF
  } > "$COMPOSE_FILE"
}

# =============================================================================
# FUNCTION: config.json generation
# =============================================================================
write_config() {
  info "Generating config.json..."

  if [[ -f "$CONFIG_FILE" ]]; then
    local bak; bak="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$bak"
    info "Previous config.json saved as ${bak}"
  fi

  local db_block
  if [[ "$DB_ENGINE" == "mongo" ]]; then
    db_block='    "mongoDb": "mongodb://mongodb:27017/meshcentral",'
  else
    db_block=$(cat <<EOF
    "mySQL": {
      "host": "mysql",
      "port": 3306,
      "user": "${MYSQL_USER}",
      "password": "${MYSQL_PASSWORD}",
      "database": "${MYSQL_DATABASE}"
    },
EOF
)
  fi

  if [[ -n "$MESH_DOMAIN" ]]; then
    # Behind a reverse proxy. "newAccounts": false still allows creating the
    # very first (admin) account.
    cat > "$CONFIG_FILE" <<EOF
{
  "settings": {
${db_block}
    "port": 443,
    "redirPort": false,
	"tlsOffload": true,
    "cert": "${MESH_DOMAIN}",
    "wanOnly": true,
    "trustedProxy": "${TRUSTED_PROXY}"
  },
  "domains": {
    "": {
      "title": "MeshCentral",
      "newAccounts": false,
      "certUrl": "https://${MESH_DOMAIN}:443/"
    }
  }
}
EOF
  else
    cat > "$CONFIG_FILE" <<EOF
{
  "settings": {
${db_block}
    "port": 443,
    "redirPort": false
  },
  "domains": {
    "": {
      "title": "MeshCentral",
      "newAccounts": true
    }
  }
}
EOF
  fi

  [[ "$DB_ENGINE" == "mysql" ]] && chmod 600 "$CONFIG_FILE"

  if command -v python3 &>/dev/null; then
    python3 -m json.tool "$CONFIG_FILE" >/dev/null || die "Generated config.json is not valid JSON."
    ok "Valid JSON syntax."
  fi
}

# =============================================================================
# FUNCTION: Wait for the database container to be healthy (with diagnosis)
# =============================================================================
diag_db_exit() {
  local code="$1"
  echo
  if [[ "$code" == "132" ]]; then
    error "${DB_CONTAINER} crashed with exit code 132 (SIGILL — Illegal Instruction)."
    echo
    line "DIAGNOSIS: Exit Code 132"
    echo "  Your CPU does not support the instruction set this image was built for."
    echo
    echo -e "${BOLD}  WHAT TO DO:${RESET}"
    if [[ "$DB_ENGINE" == "mongo" ]]; then
      echo "  Re-run the installer forcing an older MongoDB version:"
      echo "    sudo MONGO_VERSION=4.0 DB_ENGINE=mongo bash $0"
    else
      echo "  Re-run the installer and choose MongoDB, or try another MySQL image:"
      echo "    sudo MYSQL_IMAGE=mysql:8.0 DB_ENGINE=mysql bash $0"
    fi
  else
    line "DIAGNOSIS: ${DB_CONTAINER} exited (code ${code})"
    echo "  Check container logs: docker logs ${DB_CONTAINER} --tail 50"
    echo
    echo -e "${BOLD}  COMMON CAUSES:${RESET}"
    if [[ "$DB_ENGINE" == "mongo" ]]; then
      echo "  • Code 14  → Corrupted lockfile / unclean shutdown. As a last resort"
      echo "               (DELETES ALL DATA):"
      echo "    cd ${INSTALL_DIR} && docker compose down && docker volume rm ${PROJECT_NAME}_${DB_VOLUME}"
      echo "  • Code 132 → Incompatible CPU (force MONGO_VERSION=4.0)."
    else
      echo "  • Password mismatch with an existing volume (see ${ENV_FILE})."
      echo "  • Corrupted data dir. As a last resort (DELETES ALL DATA):"
      echo "    cd ${INSTALL_DIR} && docker compose down && docker volume rm ${PROJECT_NAME}_${DB_VOLUME}"
    fi
  fi
  line "━━━━━━━━━━━━━━━━━━━━━"
}

wait_for_db() {
  local status health code
  for i in $(seq 1 40); do   # 40 × 5 s = 200 s (> start_period 120 s)
    status=$(docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "missing")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$DB_CONTAINER" 2>/dev/null || true)
    code=$(docker inspect -f '{{.State.ExitCode}}' "$DB_CONTAINER" 2>/dev/null || echo "?")

    if [[ "$health" == "healthy" ]]; then
      echo >&2; return 0
    fi

    case "$status" in
      restarting)
        if [[ "$code" == "132" ]]; then diag_db_exit "$code"; die "Installation aborted."; fi ;;
      exited|dead)
        diag_db_exit "$code"; die "${DB_CONTAINER} failed to start." ;;
    esac

    printf "  [%2d/40] %s %s...\r" "$i" "$DB_CONTAINER" "${health:-$status}" >&2
    sleep 5
  done
  echo >&2
  return 1
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  # ── 0. Root & architecture checks ──────────────────────────────────────────
  [[ $EUID -eq 0 ]] || die "Must be run as root: sudo bash $0"

  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) ;;
    *) die "Unsupported architecture: ${arch}. A 64-bit OS (x86_64 or aarch64/ARM64) is required." ;;
  esac

  # ── 1. Questions ───────────────────────────────────────────────────────────
  choose_db_engine
  choose_domain

  # ── 2. System update & dependencies ────────────────────────────────────────
  export DEBIAN_FRONTEND=noninteractive
  info "Updating system packages..."
  apt-get update -qq && apt-get upgrade -y -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release iptables wget

  # ── 3. Docker installation ─────────────────────────────────────────────────
  if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    # shellcheck disable=SC1091
    . /etc/os-release
    local distro codename
    case "${ID}:${ID_LIKE:-}" in
      ubuntu:*|*:*ubuntu*) distro="ubuntu"; codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs)}}" ;;
      debian:*|raspbian:*|*:*debian*) distro="debian"; codename="${VERSION_CODENAME:-$(lsb_release -cs)}" ;;
      *) die "Unsupported distribution: ${ID}" ;;
    esac

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
      | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi
  docker compose version &>/dev/null || die "The 'docker compose' plugin is missing. Install docker-compose-plugin."

  # ── 4. Docker daemon startup check ─────────────────────────────────────────
  if ! docker info &>/dev/null; then
    info "Starting Docker daemon..."
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
      systemctl enable --now docker &>/dev/null || true
    fi
    if ! docker info &>/dev/null; then
      nohup dockerd > /var/log/dockerd.log 2>&1 &   # WSL2 without systemd
    fi
    for _ in {1..30}; do
      docker info &>/dev/null && break
      sleep 2
    done
    docker info &>/dev/null || die "Docker daemon is not responding. Check: /var/log/dockerd.log"
  fi

  # ── 5. Directory setup ─────────────────────────────────────────────────────
  mkdir -p "${DATA_DIR}" "${INSTALL_DIR}/files" "${INSTALL_DIR}/backup" "${INSTALL_DIR}/web"
  cd "${INSTALL_DIR}"

  # ── 6. Stop previous stack (with the OLD compose file) ─────────────────────
  if [[ -f "$COMPOSE_FILE" ]]; then
    info "Stopping previous stack (data volumes are kept)..."
    docker compose down --remove-orphans 2>/dev/null || true
    if [[ "$DB_ENGINE" == "mysql" ]] && grep -q 'image: mongo:' "$COMPOSE_FILE"; then
      warn "Switching from MongoDB to MySQL: existing data is NOT migrated."
    elif [[ "$DB_ENGINE" == "mongo" ]] && grep -q 'container_name: meshcentral-mysql' "$COMPOSE_FILE"; then
      warn "Switching from MySQL to MongoDB: existing data is NOT migrated."
    fi
  fi

  # ── 7. Database parameters ─────────────────────────────────────────────────
  if [[ "$DB_ENGINE" == "mongo" ]]; then
    MONGO_VERSION=$(detect_mongo_version)
  else
    prepare_mysql_env
  fi

  # ── 8. Generate files ──────────────────────────────────────────────────────
  write_compose
  docker compose -f "$COMPOSE_FILE" config -q || die "Generated docker-compose.yml is invalid."
  ok "Valid docker-compose.yml."
  write_config

  # ── 9. Deploy: database first, then the rest ───────────────────────────────
  info "Pulling Docker images..."
  docker compose pull

  info "Starting ${DB_SERVICE}..."
  docker compose up -d "$DB_SERVICE"

  echo >&2
  info "Waiting for ${DB_CONTAINER} to become healthy (up to ~3 minutes)..."
  if wait_for_db; then
    ok "${DB_SERVICE} is healthy."
  else
    warn "${DB_CONTAINER} is not healthy yet; MeshCentral will start once it is."
    warn "Check: docker logs ${DB_CONTAINER} --tail 30"
  fi

  info "Starting MeshCentral and Watchtower..."
  docker compose up -d || warn "docker compose up reported an error (see diagnosis below)."

  # ── 10. Verify MeshCentral ─────────────────────────────────────────────────
  info "Waiting for MeshCentral response on ${HOST_BIND}:${HOST_PORT}..."
  local mesh_ok=false
  for i in {1..24}; do
    if curl -sk --max-time 5 "https://${HOST_BIND}:${HOST_PORT}" >/dev/null 2>&1; then
      mesh_ok=true; break
    fi
    printf "  [%2d/24] Waiting for HTTPS server response...\r" "$i" >&2
    sleep 5
  done
  echo

  # ── 11. Final summary ──────────────────────────────────────────────────────
  echo
  echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"

  if [[ "$mesh_ok" == "true" ]]; then
    ok "MeshCentral is running (database: ${DB_ENGINE})."
    echo
    echo -e "  ${GREEN}${BOLD}→ Local access (this host only): https://localhost:${HOST_PORT}${RESET}"
    if [[ -n "$MESH_DOMAIN" ]]; then
      echo -e "  ${GREEN}${BOLD}→ Public access: https://${MESH_DOMAIN}${RESET}"
      echo "    Your reverse proxy must forward to https://127.0.0.1:${HOST_PORT}"
      echo "    with WebSockets enabled (Upgrade/Connection headers)."
    else
      echo "    Port is bound to ${HOST_BIND}: use a reverse proxy or SSH tunnel for remote access."
    fi
    echo
    echo "  The first account you create becomes the administrator."
    echo "  Self-signed certificate warnings on localhost are expected."
  else
    warn "MeshCentral is taking too long to respond on ${HOST_BIND}:${HOST_PORT}."
    echo
    line "DIAGNOSIS: MeshCentral Unresponsive"
    echo
    echo -e "${BOLD}  STEP 1 — Check container states:${RESET}"
    echo "    docker ps -a"
    echo
    echo -e "${BOLD}  STEP 2 — Check logs:${RESET}"
    echo "    docker logs meshcentral-app --tail 50"
    echo "    docker logs ${DB_CONTAINER} --tail 50"
    echo
    echo -e "${BOLD}  STEP 3 — If meshcentral-app is 'Created' or 'Restarting':${RESET}"
    echo "    The database may still be starting. Wait 2 minutes and check again:"
    echo "    curl -sk https://localhost:${HOST_PORT}"
    echo
    echo -e "${BOLD}  STEP 4 — Force manual stack restart:${RESET}"
    echo "    cd ${INSTALL_DIR} && docker compose up -d"
    line "━━━━━━━━━━━━━━━━━━━━━"
  fi

  echo
  echo -e "${BOLD}  Useful Commands:${RESET}"
  echo "    Live logs:       docker compose -f ${COMPOSE_FILE} logs -f"
  echo "    Status:          docker compose -f ${COMPOSE_FILE} ps"
  echo "    Restart stack:   docker compose -f ${COMPOSE_FILE} restart"
  echo "    Wipe database:   cd ${INSTALL_DIR} && docker compose down && docker volume rm ${PROJECT_NAME}_${DB_VOLUME}"
  [[ "$DB_ENGINE" == "mysql" ]] && echo "    MySQL passwords: ${ENV_FILE}"
  echo
  echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
  echo
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Run main only when executed (allows "source" for testing)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
