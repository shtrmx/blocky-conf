#!/usr/bin/env bash
set -euo pipefail

# --- Default Variables ---
INSTALL_DIR="${BLOCKY_INSTALL_DIR:-/opt/blocky}"
BLOCKY_TAG="${BLOCKY_TAG:-latest}"
BLOCKY_PORT="${BLOCKY_PORT:-53}"
RESOLVED_STUB="/etc/systemd/resolved.conf.d/blocky.conf"

# --- Root Privileges Check ---
require_root() {
  if [[ $EUID -ne 0 ]]; then
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"sh"* && "$0" != *"/dev/fd/"* && "$0" != *"/proc/"* ]]; then
      echo "🔑 Root privileges required. Requesting sudo..."
      exec sudo bash "$0" "$@"
    else
      echo "❌ Root privileges required!" >&2
      echo "Run the command with sudo:" >&2
      echo "  sudo bash ./installer.sh" >&2
      exit 1
    fi
  fi
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

# --- Install UI Tool (gum) ---
install_gum() {
  command -v gum &>/dev/null && return 0
  echo "📦 Installing UI utility (gum)..."
  local distro
  distro=$(detect_distro)

  case "$distro" in
    arch|manjaro|endeavouros)
      pacman -Sy --noconfirm gum
      ;;
    ubuntu|debian|pop|linuxmint)
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
      apt-get update -qq
      apt-get install -y gum
      ;;
    fedora|rhel|centos)
      dnf install -y gum
      ;;
    *)
      install_gum_binary
      ;;
  esac
}

install_gum_binary() {
  local arch version tarball tmp
  arch=$(uname -m)
  case "$arch" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac

  version=$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest | grep -oP '"tag_name": "\K[^"]+')
  tarball="gum_${version#v}_Linux_${arch}.tar.gz"
  tmp=$(mktemp -d)

  curl -fsSL "https://github.com/charmbracelet/gum/releases/download/${version}/${tarball}" -o "$tmp/gum.tar.gz"
  tar -xzf "$tmp/gum.tar.gz" -C "$tmp"
  install -m 755 "$tmp"/gum_*/gum /usr/local/bin/gum
  rm -rf "$tmp"
}

# --- Interactive Settings ---
configure_settings() {
  INSTALL_DIR=$(gum input --value "$INSTALL_DIR" --header "Blocky Installation Directory:" --placeholder "/opt/blocky")
  BLOCKY_TAG=$(gum input --value "$BLOCKY_TAG" --header "Blocky Docker Tag (e.g., latest, v0.24):" --placeholder "latest")
  BLOCKY_PORT=$(gum input --value "$BLOCKY_PORT" --header "Blocky DNS Port (53 for standalone, 5353 for FLClash chain):" --placeholder "53")

  gum style --foreground 82 "Path: $INSTALL_DIR"
  gum style --foreground 82 "Version: ghcr.io/0xerr0r/blocky:$BLOCKY_TAG"
  gum style --foreground 82 "DNS Port: $BLOCKY_PORT"
}

# --- Dependency Check ---
check_dependency() {
  local bin=$1 label=$2
  if command -v "$bin" &>/dev/null; then
    gum style --foreground 42 "✓ $label found"
    return 0
  fi
  gum style --foreground 196 "✗ $label is missing"
  return 1
}

install_docker() {
  local distro
  distro=$(detect_distro)
  gum spin --spinner dot --title "Installing Docker..." -- bash -c "
    case '$distro' in
      arch|manjaro|endeavouros) pacman -Sy --noconfirm docker docker-compose ;;
      fedora|rhel|centos) dnf install -y docker docker-compose-plugin ;;
      *) curl -fsSL https://get.docker.com | sh ;;
    esac
    systemctl enable --now docker
  "
}

check_dependencies() {
  local missing=0
  check_dependency curl "curl" || missing=1
  check_dependency git "git" || missing=1

  if ! command -v docker &>/dev/null; then
    gum style --foreground 196 "✗ Docker is missing"
    if gum confirm "Install Docker automatically?"; then
      install_docker
    else
      missing=1
    fi
  else
    gum style --foreground 42 "✓ Docker found"
  fi

  if ! docker compose version &>/dev/null; then
    gum style --foreground 196 "✗ Docker Compose plugin is missing"
    missing=1
  else
    gum style --foreground 42 "✓ Docker Compose found"
  fi

  if [[ $missing -eq 1 ]]; then
    gum style --foreground 196 "Dependency errors. Installation aborted."
    exit 1
  fi
}

# --- Setup Configuration Files ---
setup_configs() {
  mkdir -p "$INSTALL_DIR"

  if [[ -f "$INSTALL_DIR/docker-compose.yml" || -f "$INSTALL_DIR/config.yml" ]]; then
    if ! gum confirm "Configuration files already exist in $INSTALL_DIR. Overwrite?"; then
      gum style --foreground 244 "Skipping configuration overwrite."
      return 0
    fi
  fi

  # Используем unquoted EOF для подстановки переменных в docker-compose.yml
  cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  blocky:
    image: ghcr.io/0xerr0r/blocky:${BLOCKY_TAG}
    container_name: blocky
    restart: unless-stopped
    ports:
      - "${BLOCKY_PORT}:53/tcp"
      - "${BLOCKY_PORT}:53/udp"
      - "4000:4000/tcp"
    environment:
      - TZ=UTC
    volumes:
      - ./config.yml:/app/config.yml
      - blocky_cache:/app/cache
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:4000/api/blocking/status"]
      interval: 30s
      timeout: 5s
      retries: 3
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true

volumes:
  blocky_cache:
EOF

  cat > "$INSTALL_DIR/config.yml" <<'EOF'
upstreams:
  groups:
    default:
      - https://dns.cloudflare.com/dns-query
      - https://dns.quad9.net/dns-query
  strategy: parallel_best
  timeout: 2s

bootstrapDns:
  - upstream: https://1.1.1.1/dns-query
    ips:
      - 1.1.1.1

blocking:
  denylists:
    ads:
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/refs/heads/main/dnsmasq/ultimate.mini.txt
      https://raw.githubusercontent.com/hagezi/dns-blocklists/refs/heads/main/dnsmasq/pro.plus.txt
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/refs/heads/main/dnsmasq/popupads.txt
    yandex:
      - https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst
      - https://raw.githubusercontent.com/Zalexanninev15/NoADS_RU/main/ads_list.txt
    malware:
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/refs/heads/main/dnsmasq/tif.mini.txt
  clientGroupsBlock:
    default:
      - ads
      - yandex
      - malware
  blockType: zeroIp
  blockTTL: 6h
  loading:
    refreshPeriod: 24h
    downloads:
      timeout: 60s
      attempts: 3
      cooldown: 10s

caching:
  minTime: 5m
  maxTime: 30m
  prefetching: true

ports:
  dns: 53
  http: 4000

log:
  level: info
  format: text
  timestamp: true
EOF

  gum style --foreground 42 "✓ Configuration created successfully in $INSTALL_DIR"
}

# --- Start Container ---
start_blocky() {
  # Освобождаем порт 53 только если Blocky должен слушать порт 53
  if [[ "$BLOCKY_PORT" == "53" ]] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p "$(dirname "$RESOLVED_STUB")"
    cat > "$RESOLVED_STUB" <<'EOF'
[Resolve]
DNSStubListener=no
EOF
    systemctl reload-or-restart systemd-resolved
  fi

  gum spin --spinner line --title "Pulling image and starting container..." -- \
    docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d --pull always

  gum style --foreground 42 "✓ Blocky container started on port $BLOCKY_PORT!"
}

# --- System DNS Management ---
configure_system_dns() {
  if [[ "$BLOCKY_PORT" != "53" ]]; then
    gum style --foreground 214 "⚠ Blocky is configured on port $BLOCKY_PORT (not 53). System /etc/resolv.conf won't be modified directly. Route traffic via FLClash/SmartDNS."
    return 0
  fi

  gum spin --spinner dot --title "Applying system DNS settings to route to Blocky..." -- bash -c "
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      mkdir -p '$(dirname "$RESOLVED_STUB")'
      cat > '$RESOLVED_STUB' <<'EOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
      systemctl reload-or-restart systemd-resolved
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
      [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
      cat > /etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
options edns0
EOF
    fi
  "
  gum style --foreground 42 "✓ System DNS routed to 127.0.0.1"
}

restore_system_dns() {
  gum spin --spinner dot --title "Restoring original system DNS settings..." -- bash -c "
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      rm -f '$RESOLVED_STUB'
      systemctl reload-or-restart systemd-resolved
      ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    else
      [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
      cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    fi
  "
  gum style --foreground 42 "✓ System DNS restored to default."
}

# --- Health and Status Check ---
check_status() {
  gum spin --spinner pulse --title "Waiting for services to initialize..." -- sleep 3

  local container_state
  container_state=$(docker inspect -f '{{.State.Status}}' blocky 2>/dev/null || echo "not_found")

  if [[ "$container_state" != "running" ]]; then
    gum style --foreground 196 "✗ Blocky container is not running (Status: $container_state)"
    return 1
  fi
  gum style --foreground 42 "✓ Blocky container is active"

  if curl -fsS -m 2 'http://127.0.0.1:4000/api/blocking/status' &>/dev/null; then
    gum style --foreground 42 "✓ REST API responding on port 4000"
  else
    gum style --foreground 196 "✗ REST API is not responding"
  fi

  if command -v dig &>/dev/null; then
    local dig_result
    dig_result=$(dig @"127.0.0.1" -p "$BLOCKY_PORT" doubleclick.net +short +time=2 2>/dev/null || true)
    if [[ "$dig_result" == "0.0.0.0" ]]; then
      gum style --foreground 42 "✓ Ad-blocking test successful (doubleclick.net returned 0.0.0.0)"
    else
      gum style --foreground 214 "⚠ DNS response for test domain: '${dig_result:-empty}'. Check blocklists."
    fi
  else
    gum style --foreground 244 "dig utility not found. Skipping DNS test."
  fi

  gum style --border rounded --padding "1 2" --foreground 51 \
    "Blocky Operational 🚀
Dir: $INSTALL_DIR
DNS Port: $BLOCKY_PORT
Logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
}

# --- Uninstall Logic ---
uninstall_blocky() {
  if ! gum confirm "Are you sure you want to completely uninstall Blocky and its data?"; then
    gum style --foreground 244 "Uninstallation aborted."
    return 0
  fi

  echo "🗑 Uninstalling Blocky..."
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    docker compose -f "$INSTALL_DIR/docker-compose.yml" down -v || true
  fi

  rm -rf "$INSTALL_DIR"
  restore_system_dns
  gum style --foreground 42 "✓ Blocky has been completely removed."
}

# --- Main Menu ---
menu() {
  while true; do
    echo ""
    local CHOICE
    CHOICE=$(gum choose \
      "1. Full Installation (All Steps)" \
      "2. Configure Settings (Path, Tag, Port)" \
      "3. Install Dependencies" \
      "4. Generate Configuration Files" \
      "5. Start/Restart Blocky Container" \
      "6. Install DNS (Route System via Blocky)" \
      "7. Remove DNS (Restore Default System DNS)" \
      "8. Check Status and Test" \
      "9. Uninstall Blocky" \
      "0. Exit")

    case "$CHOICE" in
      "1. "* )
        configure_settings
        check_dependencies
        setup_configs
        start_blocky
        configure_system_dns
        check_status
        ;;
      "2. "* ) configure_settings ;;
      "3. "* ) check_dependencies ;;
      "4. "* ) setup_configs ;;
      "5. "* ) start_blocky ;;
      "6. "* ) configure_system_dns ;;
      "7. "* ) restore_system_dns ;;
      "8. "* ) check_status ;;
      "9. "* ) uninstall_blocky ;;
      "0. "* ) exit 0 ;;
    esac
  done
}

main() {
  require_root
  install_gum
  gum style --border double --padding "1 4" --foreground 213 --bold "Blocky Installer & Manager v1.0"
  menu
}

main "$@"
