#!/usr/bin/env bash
set -euo pipefail

# --- Значения по умолчанию ---
INSTALL_DIR="${BLOCKY_INSTALL_DIR:-/opt/blocky}"
BLOCKY_TAG="${BLOCKY_TAG:-latest}"
RESOLVED_STUB="/etc/systemd/resolved.conf.d/blocky.conf"

# --- Автозапрос прав root (Sudo) ---
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "🔑 Для установки требуются права root. Запрашиваю sudo..."
    if command -v sudo &>/dev/null; then
      exec sudo bash "$0" "$@"
    else
      echo "✗ Команда sudo не найдена. Запустите скрипт от root." >&2
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

# --- Автоустановка gum ---
install_gum() {
  command -v gum &>/dev/null && return 0

  echo "📦 Установка утилиты UI (gum)..."
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
    *) echo "Неподдерживаемая архитектура: $arch" >&2; exit 1 ;;
  esac

  version=$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest | grep -oP '"tag_name": "\K[^"]+')
  tarball="gum_${version#v}_Linux_${arch}.tar.gz"
  tmp=$(mktemp -d)

  curl -fsSL "https://github.com/charmbracelet/gum/releases/download/${version}/${tarball}" -o "$tmp/gum.tar.gz"
  tar -xzf "$tmp/gum.tar.gz" -C "$tmp"
  install -m 755 "$tmp"/gum_*/gum /usr/local/bin/gum
  rm -rf "$tmp"
}

# --- Интерактивная настройка параметров ---
configure_settings() {
  gum style --border rounded --padding "1 2" --foreground 213 "Параметры установки"

  INSTALL_DIR=$(gum input --value "$INSTALL_DIR" --header "Путь к директории установки Blocky:" --placeholder "/opt/blocky")
  BLOCKY_TAG=$(gum input --value "$BLOCKY_TAG" --header "Тег / Версия образа Blocky (например, latest, v0.23):" --placeholder "latest")

  gum style --foreground 82 "Путь: $INSTALL_DIR"
  gum style --foreground 82 "Версия: ghcr.io/0xerr0r/blocky:$BLOCKY_TAG"
}

# --- Проверка зависимостей ---
check_dependency() {
  local bin=$1 label=$2
  if command -v "$bin" &>/dev/null; then
    gum style --foreground 42 "✓ $label найден"
    return 0
  fi
  gum style --foreground 196 "✗ $label отсутствует"
  return 1
}

install_docker() {
  local distro
  distro=$(detect_distro)

  gum spin --spinner dot --title "Устанавливаю Docker..." -- bash -c "
    case '$distro' in
      arch|manjaro|endeavouros)
        pacman -Sy --noconfirm docker docker-compose
        ;;
      fedora|rhel|centos)
        dnf install -y docker docker-compose-plugin
        ;;
      *)
        curl -fsSL https://get.docker.com | sh
        ;;
    esac
    systemctl enable --now docker
  "
}

check_dependencies() {
  gum style --border rounded --padding "1 2" --foreground 213 "Проверка системных зависимостей"

  local missing=0

  check_dependency curl "curl" || missing=1
  check_dependency git "git" || missing=1

  if ! command -v docker &>/dev/null; then
    gum style --foreground 196 "✗ Docker отсутствует"
    if gum confirm "Установить Docker автоматически?"; then
      install_docker
    else
      missing=1
    fi
  else
    gum style --foreground 42 "✓ Docker найден"
  fi

  if ! docker compose version &>/dev/null; then
    gum style --foreground 196 "✗ Docker Compose plugin отсутствует"
    missing=1
  else
    gum style --foreground 42 "✓ Docker Compose найден"
  fi

  if [[ $missing -eq 1 ]]; then
    gum style --foreground 196 "Ошибки зависимостей. Установка приостановлена."
    return 1
  fi
}

# --- Генерация файлов конфигурации ---
setup_configs() {
  gum style --border rounded --padding "1 2" --foreground 213 "Создание файлов конфигурации"

  mkdir -p "$INSTALL_DIR"

  if [[ -f "$INSTALL_DIR/docker-compose.yml" || -f "$INSTALL_DIR/config.yml" ]]; then
    if ! gum confirm "Файлы конфигурации уже существуют в $INSTALL_DIR. Перезаписать?"; then
      gum style --foreground 244 "Пропускаем перезапись файлов."
      return 0
    fi
  fi

  gum spin --spinner dot --title "Запись docker-compose.yml и config.yml..." -- bash -c "
    cat > '$INSTALL_DIR/docker-compose.yml' <<'EOF'
services:
  blocky:
    image: ghcr.io/0xerr0r/blocky:${BLOCKY_TAG}
    container_name: blocky
    restart: unless-stopped
    ports:
      - \"53:53/tcp\"
      - \"53:53/udp\"
      - \"4000:4000/tcp\"
    environment:
      - TZ=Europe/Moscow
    volumes:
      - ./config.yml:/app/config.yml
      - blocky_cache:/app/cache
    healthcheck:
      test: [\"CMD\", \"wget\", \"--spider\", \"-q\", \"http://localhost:4000/api/blocking/status\"]
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

    cat > '$INSTALL_DIR/config.yml' <<'EOF'
upstreams:
  init:
    strategy: fast
  groups:
    default:
      - https://dns.cloudflare.com/dns-query
      - https://dns.quad9.net/dns-query
      - tcp-tls:one.one.one.one
  strategy: parallel_best
  timeout: 5s

bootstrapDns:
  - upstream: https://one.one.one.one/dns-query
    ips:
      - 1.1.1.1
      - 1.0.0.1

blocking:
  denylists:
    ads:
      - https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt
      - https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
    malware:
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/tif.txt
      - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/badware.hoster.txt
      - https://urlhaus.abuse.ch/downloads/hostfile/
    yandex_ads:
      - |
        an.yandex.ru
        mc.yandex.ru
        yabs.yandex.ru
        yandexadexchange.net
        yandex.ru/ads
        awaps.yandex.ru
        bs.yandex.ru
        banners.adfox.ru
        ads.adfox.ru
        adfox.yandex.ru
        an.yandex.com
        strm.yandex.ru
        strm.yandex.net

  clientGroupsBlock:
    default:
      - ads
      - malware
      - yandex_ads

  blockType: zeroIp
  blockTTL: 6h

  loading:
    refreshPeriod: 4h
    downloads:
      timeout: 60s
      attempts: 3
      cooldown: 5s
    strategy: failOnError
    concurrency: 4

  cache:
    path: /app/cache

caching:
  minTime: 5m
  maxTime: 30m
  prefetching: true
  prefetchThreshold: 5
  maxItemsCount: 100000

ports:
  dns: 53
  http: 4000

log:
  level: info
  format: text
  timestamp: true

minTlsServeVersion: \"1.2\"
EOF
  "

  gum style --foreground 42 "✓ Файлы успешно созданы в $INSTALL_DIR"
}

# --- Освобождение 53 порта и запуск ---
start_blocky() {
  gum style --border rounded --padding "1 2" --foreground 213 "Запуск контейнера Blocky"

  # Предварительно освобождаем 53 порт от systemd-resolved DNSStubListener
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    gum spin --spinner dot --title "Освобождаем порт 53 (отключение DNSStubListener)..." -- bash -c "
      mkdir -p '$(dirname "$RESOLVED_STUB")'
      cat > '$RESOLVED_STUB' <<'EOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
      systemctl reload-or-restart systemd-resolved
    "
  fi

  gum spin --spinner line --title "Загрузка Docker-образа и запуск контейнера..." -- \
    docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d --pull always

  gum style --foreground 42 "✓ Контейнер Blocky успешно поднят!"
}

# --- Настройка системного DNS ---
configure_system_dns() {
  gum style --border rounded --padding "1 2" --foreground 213 "Настройка системного DNS"

  if ! gum confirm "Направить системный DNS локально на 127.0.0.1 (blocky)?"; then
    gum style --foreground 244 "Пропускаем настройку DNS."
    return 0
  fi

  gum spin --spinner dot --title "Применение настроек DNS..." -- bash -c "
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
      [[ -L /etc/resolv.conf ]] && rm -f /etc/resolv.conf
      cat > /etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
options edns0
EOF
    fi
  "
  gum style --foreground 42 "✓ DNS системы успешно направлен на 127.0.0.1"
}

# --- Проверка работоспособности ---
check_status() {
  gum style --border rounded --padding "1 2" --foreground 213 "Проверка статуса"

  gum spin --spinner pulse --title "Ожидание запуска сервисов..." -- sleep 3

  local container_state
  container_state=$(docker inspect -f '{{.State.Status}}' blocky 2>/dev/null || echo "not_found")

  if [[ "$container_state" != "running" ]]; then
    gum style --foreground 196 "✗ Контейнер blocky не запущен (статус: $container_state)"
    docker compose -f "$INSTALL_DIR/docker-compose.yml" logs --tail=30 blocky
    return 1
  fi
  gum style --foreground 42 "✓ Контейнер blocky активен"

  # Проверка API с помощью spin
  local api_ok=false
  gum spin --spinner dot --title "Запрос к REST API (:4000)..." -- bash -c "
    curl -fsS 'http://127.0.0.1:4000/api/blocking/status' &>/dev/null
  " && api_ok=true || api_ok=false

  if [[ "$api_ok" == "true" ]]; then
    gum style --foreground 42 "✓ REST API работает на :4000"
  else
    gum style --foreground 196 "✗ REST API не отвечает"
  fi

  # DNS-тест
  if command -v dig &>/dev/null; then
    local dig_result=""
    dig_result=$(dig @127.0.0.1 an.yandex.ru +short +time=3 2>/dev/null || true)
    if [[ "$dig_result" == "0.0.0.0" ]]; then
      gum style --foreground 42 "✓ Тестовый домен (an.yandex.ru) успешно заблокирован (0.0.0.0)"
    else
      gum style --foreground 214 "⚠ Ответ DNS: '${dig_result:-пусто}' (проверьте правила блокировки)"
    fi
  else
    gum style --foreground 244 "dig не найден, проверка резолвинга пропущена."
  fi

  gum style --border rounded --padding "1 2" --foreground 51 \
    "Установка завершена! 🚀
Порты: DNS (53), API (:4000)
Директория: $INSTALL_DIR
Просмотр логов: docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
}

# --- Главное меню ---
menu() {
  while true; do
    echo ""
    local CHOICE
    CHOICE=$(gum choose \
      "🚀 Полная установка (Все этапы)" \
      "⚙️  Настроить параметры (Путь и Версия)" \
      "📦 Проверить и установить зависимости" \
      "📝 Создать/Обновить конфигурации" \
      "🐳 Запустить / Перезапустить Blocky" \
      "🌐 Направить системный DNS на Blocky" \
      "🔍 Проверить статус и провести тесты" \
      "❌ Выход")

    case "$CHOICE" in
      "🚀 Полная установка (Все этапы)")
        configure_settings
        check_dependencies
        setup_configs
        start_blocky
        configure_system_dns
        check_status
        break
        ;;
      "⚙️  Настроить параметры (Путь и Версия)")
        configure_settings
        ;;
      "📦 Проверить и установить зависимости")
        check_dependencies
        ;;
      "📝 Создать/Обновить конфигурации")
        setup_configs
        ;;
      "🐳 Запустить / Перезапустить Blocky")
        start_blocky
        ;;
      "🌐 Направить системный DNS на Blocky")
        configure_system_dns
        ;;
      "🔍 Проверить статус и провести тесты")
        check_status
        ;;
      "❌ Выход")
        echo "До связи!"
        exit 0
        ;;
    esac
  done
}

main() {
  require_root
  install_gum
  gum style --border double --padding "1 4" --foreground 213 --bold "Blocky Interactive Installer"
  menu
}

main "$@"