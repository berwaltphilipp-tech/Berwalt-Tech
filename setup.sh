#!/usr/bin/env bash
# Richtet das Berwalt-Tech Dashboard automatisch ein.
#
#   sudo ./setup.sh
#
# Erkennt Server-IP, Netzwerkkarte, Festplatte, UDM und CPU-Sensor selbst,
# prüft FRITZ!Box und UDM, schreibt die .env und startet alles.
# Kann gefahrlos mehrfach ausgeführt werden.
#
# Ohne Rückfragen (z. B. für Automatisierung) lassen sich Werte vorgeben:
#   FRITZBOX_IP=192.168.178.1 UNIFI_IP=192.168.1.1 UNIFI_KEY=... sudo -E ./setup.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$*"; exit 1; }

# Frage stellen; ohne Terminal (oder bei leerer Eingabe) gilt der Vorgabewert.
HAVE_TTY=""
if (exec </dev/tty >/dev/tty) 2>/dev/null; then HAVE_TTY=1; fi
ask() {
  local prompt=$1 default=${2:-} silent=${3:-} answer=""
  if [ -n "$HAVE_TTY" ]; then
    printf '  %s%s: ' "$prompt" "${default:+ [$default]}" >/dev/tty
    if [ -n "$silent" ]; then
      read -r -s answer </dev/tty || true
      echo >/dev/tty
    else
      read -r answer </dev/tty || true
    fi
  fi
  printf '%s' "${answer:-$default}"
}

# Wert in .env setzen (sicher auch bei Sonderzeichen)
set_env() {
  K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    index($0, k "=") == 1 { print k "=" v; next } { print }' .env > .env.tmp
  mv .env.tmp .env
  chmod 600 .env  # enthält den API-Schlüssel
}
get_env() { grep -m1 "^$1=" .env | cut -d= -f2-; }

[ "$(uname -s)" = Linux ] || fail "Dieses Skript ist für Linux-Server (Windows: siehe README)."
[ "$(id -u)" -eq 0 ] || fail "Bitte mit sudo starten:  sudo ./setup.sh"
command -v curl >/dev/null || fail "curl fehlt. Installieren mit:  sudo apt install curl"

# --------------------------------------------------------------------------
say "1/6  Docker"
if ! command -v docker >/dev/null; then
  if [ "$(ask 'Docker ist nicht installiert. Jetzt installieren? (j/n)' j)" = j ]; then
    curl -fsSL https://get.docker.com | sh
  else
    fail "Ohne Docker geht es nicht."
  fi
fi
docker compose version >/dev/null 2>&1 || fail "Docker Compose fehlt (Paket docker-compose-plugin)."
if ! docker info >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  sleep 3
  docker info >/dev/null 2>&1 || fail "Docker läuft nicht. Starten mit:  sudo systemctl start docker"
fi
ok "$(docker --version)"

# --------------------------------------------------------------------------
say "2/6  Netzwerk erkennen"
GW="" IFACE="" SRC=""
if command -v ip >/dev/null; then
  IFS=';' read -r GW IFACE SRC < <(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) { if ($i == "via") g = $(i+1); if ($i == "dev") d = $(i+1); if ($i == "src") s = $(i+1) }
  } END { print g ";" d ";" s }') || true
fi
if [ -z "$IFACE" ]; then  # Rückfall ohne "ip"-Befehl
  IFACE=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route)
  hex=$(awk '$2 == "00000000" { print $3; exit }' /proc/net/route)
  [ -n "$hex" ] && GW=$(printf '%d.%d.%d.%d' "0x${hex:6:2}" "0x${hex:4:2}" "0x${hex:2:2}" "0x${hex:0:2}")
  SRC=$(hostname -I 2>/dev/null | awk '{ print $1 }')
fi
[ -n "$SRC" ] || fail "Keine IP-Adresse gefunden. Ist der Server mit dem Netzwerk verbunden?"
ok "Server-IP:     $SRC"
ok "Netzwerkkarte: $IFACE"
ok "Router (UDM):  ${GW:-nicht gefunden}"

ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
DISK=$(lsblk -rsno NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2 == "disk" { print $1; exit }' || true)
[ -n "$DISK" ] || DISK=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 !~ /^(loop|zram|ram)/ { print $1; exit }' || true)
DISK=${DISK:-sda}
ok "Festplatte:    $DISK"

# --------------------------------------------------------------------------
say "3/6  FRITZ!Box prüfen"
fritz_status() {  # 200 = UPnP-Status freigegeben, 000 = nicht erreichbar
  curl --noproxy '*' -s -m 4 -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    -H 'SoapAction: urn:schemas-upnp-org:service:WANIPConnection:1#GetStatusInfo' \
    -d "<?xml version='1.0'?><s:Envelope xmlns:s='http://schemas.xmlsoap.org/soap/envelope/' s:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/'><s:Body><u:GetStatusInfo xmlns:u='urn:schemas-upnp-org:service:WANIPConnection:1'/></s:Body></s:Envelope>" \
    "http://$1:49000/igdupnp/control/WANIPConn1" || true
}
FRITZ=${FRITZBOX_IP:-192.168.178.1}
code=$(fritz_status "$FRITZ")
if [ "$code" = 000 ]; then
  warn "Unter $FRITZ antwortet keine FRITZ!Box."
  FRITZ=$(ask 'IP-Adresse der FRITZ!Box' "$FRITZ")
  code=$(fritz_status "$FRITZ")
fi
FRITZ_HINT=""
case "$code" in
  200) ok "FRITZ!Box $FRITZ liefert Traffic-Daten" ;;
  000) warn "FRITZ!Box $FRITZ nicht erreichbar, Internet-Kacheln bleiben leer"; FRITZ_HINT=1 ;;
  *)   warn "FRITZ!Box erreichbar, aber Statusinformationen sind gesperrt"; FRITZ_HINT=1 ;;
esac

# --------------------------------------------------------------------------
say "4/6  UDM prüfen"
UNIFI=${UNIFI_IP:-${GW:-192.168.1.1}}
unifi_status() {  # 200 = Schlüssel gültig, 401/403 = falsch, 000 = nicht erreichbar
  curl --noproxy '*' -sk -m 5 -o /dev/null -w '%{http_code}' -H "X-API-KEY: $2" \
    "https://$1/proxy/network/api/stat/sites" || true
}
if [ "$(curl --noproxy '*' -sk -m 4 -o /dev/null -w '%{http_code}' "https://$UNIFI/" || true)" = 000 ]; then
  warn "Unter $UNIFI antwortet keine UDM."
  UNIFI=$(ask 'IP-Adresse der UDM' "$UNIFI")
fi
UNIFI_KEY=${UNIFI_KEY:-}
if [ -z "$UNIFI_KEY" ] && [ -f .env ]; then UNIFI_KEY=$(get_env HOMEPAGE_VAR_UNIFI_KEY || true); fi
if [ -z "$UNIFI_KEY" ]; then
  echo "  Für die Heimnetz-Kachel braucht das Dashboard einen API-Schlüssel der UDM:"
  echo "  UniFi Network -> Einstellungen -> Control Plane -> Integrations -> API-Schlüssel erstellen"
  UNIFI_KEY=$(ask 'API-Schlüssel einfügen (leer = später)' '' silent)
fi
UNIFI_HINT=""
if [ -n "$UNIFI_KEY" ]; then
  case "$(unifi_status "$UNIFI" "$UNIFI_KEY")" in
    200) ok "UDM $UNIFI: API-Schlüssel funktioniert" ;;
    000) warn "UDM $UNIFI nicht erreichbar"; UNIFI_HINT=1 ;;
    *)   warn "UDM $UNIFI lehnt den API-Schlüssel ab"; UNIFI_HINT=1 ;;
  esac
else
  warn "Kein API-Schlüssel, Heimnetz-Kachel bleibt vorerst leer"; UNIFI_HINT=1
fi

# --------------------------------------------------------------------------
say "5/6  Einstellungen speichern (.env)"
[ -f .env ] || cp .env.example .env
HOSTS="$SRC:3000"
[ -n "$(hostname)" ] && HOSTS="$HOSTS,$(hostname):3000,$(hostname).local:3000"
set_env HOMEPAGE_ALLOWED_HOSTS "$HOSTS"
set_env HOMEPAGE_VAR_SERVER_IP "$SRC"
set_env HOMEPAGE_VAR_NET_IFACE "$IFACE"
set_env HOMEPAGE_VAR_DISK "$DISK"
set_env HOMEPAGE_VAR_FRITZBOX_URL "http://$FRITZ"
set_env HOMEPAGE_VAR_UNIFI_URL "https://$UNIFI"
set_env HOMEPAGE_VAR_UNIFI_KEY "$UNIFI_KEY"
ok ".env geschrieben"

# --------------------------------------------------------------------------
say "6/6  Dashboard starten"
docker compose pull -q
docker compose up -d --remove-orphans

# CPU-Temperatursensor erkennen, sobald Glances läuft
sensors=""
for _ in $(seq 1 30); do
  sensors=$(curl --noproxy '*' -s -m 2 http://127.0.0.1:61208/api/4/sensors || true)
  [ -n "$sensors" ] && break
  sleep 2
done
SENSOR=""
for s in "Package id 0" "Tctl" "Tdie" "cpu_thermal 0" "cpu_thermal" "k10temp" "coretemp" "CPU" "acpitz 0" "acpitz"; do
  if grep -q "\"label\": *\"$s\"" <<<"$sensors"; then SENSOR=$s; break; fi
done
if [ -n "$SENSOR" ]; then
  set_env HOMEPAGE_VAR_CPU_SENSOR "$SENSOR"
  ok "CPU-Sensor:    $SENSOR"
else
  warn "Kein CPU-Temperatursensor gefunden (in virtuellen Maschinen normal)"
fi
# Neu starten, damit Homepage den Sensor übernimmt und alte Anmeldefehler vergisst
docker compose up -d --force-recreate homepage >/dev/null 2>&1

# --------------------------------------------------------------------------
printf '\n\033[1;32mFertig! Dashboard:  http://%s:3000\033[0m\n' "$SRC"
if [ -n "$FRITZ_HINT" ]; then
  cat <<EOF

  Noch zu tun in der FRITZ!Box (http://$FRITZ):
    Heimnetz -> Netzwerk -> Netzwerkeinstellungen
    [x] Zugriff für Anwendungen zulassen
    [x] Statusinformationen über UPnP übertragen
EOF
fi
if [ -n "$UNIFI_HINT" ]; then
  cat <<EOF

  Noch zu tun in der UDM (https://$UNIFI):
    UniFi Network -> Einstellungen -> Control Plane -> Integrations -> API-Schlüssel erstellen
EOF
fi
if [ -n "$FRITZ_HINT$UNIFI_HINT" ]; then
  echo
  echo "  Danach einfach nochmal:  sudo ./setup.sh"
fi
echo
