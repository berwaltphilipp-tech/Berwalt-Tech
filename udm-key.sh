#!/usr/bin/env bash
# API-Schlüssel der UniFi Dream Machine (UDM) im Dashboard eintragen oder ändern.
#
# In der Proxmox-Shell einfügen:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/berwaltphilipp-tech/Berwalt-Tech/HEAD/udm-key.sh)"
#
# Ohne Proxmox im Dashboard-Ordner:  sudo ./udm-key.sh
#
# Das Skript fragt nach dem Schlüssel, prüft ihn direkt an der UDM, speichert ihn
# und startet das Dashboard neu. Ist er falsch, wird nochmal gefragt.
set -euo pipefail

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$*"; exit 1; }

HAVE_TTY=""
if (exec </dev/tty >/dev/tty) 2>/dev/null; then HAVE_TTY=1; fi
ask() {  # sichtbare Eingabe mit Vorgabewert
  local answer=""
  if [ -n "$HAVE_TTY" ]; then
    printf '  %s [%s]: ' "$1" "$2" >/dev/tty
    read -r answer </dev/tty || true
  fi
  printf '%s' "${answer:-$2}"
}
ask_secret() {  # unsichtbare Eingabe
  local answer=""
  if [ -n "$HAVE_TTY" ]; then
    printf '  %s: ' "$1" >/dev/tty
    read -r -s answer </dev/tty || true
    echo >/dev/tty
  fi
  printf '%s' "$answer"
}

[ "$(id -u)" -eq 0 ] || fail "Bitte als root ausführen (Proxmox-Shell bzw. sudo)."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Wo läuft das Dashboard? --------------------------------------------------
if command -v pct >/dev/null; then
  CTID=$(pct list | awk 'NR > 1 && $NF == "dashboard" { print $1 }' | head -1 || true)
  [ -n "$CTID" ] || fail "Kein Container \"dashboard\" gefunden. Bitte zuerst das Dashboard installieren (siehe README)."
  APP=/opt/berwalt-tech
  run() { pct exec "$CTID" -- bash -c "$1"; }
  put() { pct push "$CTID" "$1" "$2" --perms 600; }
  WHERE="Container $CTID"
else
  if [ -f ./.env ] && [ -f ./docker-compose.yml ]; then APP=$PWD; else APP=/opt/berwalt-tech; fi
  [ -f "$APP/.env" ] || fail "Keine Dashboard-Einstellungen gefunden. Bitte im Dashboard-Ordner ausführen."
  run() { bash -c "$1"; }
  put() { install -m 600 "$1" "$2"; }
  WHERE=$APP
fi

# Prüft den Schlüssel an der UDM und speichert ihn bei Erfolg.
# Ausgabe: OK, oder der HTTP-Code (000 = UDM nicht erreichbar).
cat > "$TMP/apply.sh" <<'EOF'
set -eu
APP=$1 URL=$2
KEY=$(cat /root/.dashboard-udm-key)
rm -f /root/.dashboard-udm-key
code=$(curl --noproxy '*' -sk -m 6 -o /dev/null -w '%{http_code}' \
  -H "X-API-KEY: $KEY" -H "Accept: application/json" "$URL/proxy/network/api/stat/sites" || true)
if [ "$code" != 200 ]; then echo "$code"; exit 0; fi
cd "$APP"
for kv in "HOMEPAGE_VAR_UNIFI_KEY=$KEY" "HOMEPAGE_VAR_UNIFI_URL=$URL"; do
  K=${kv%%=*} V=${kv#*=} awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    index($0, k "=") == 1 { print k "=" v; found = 1; next } { print }
    END { if (!found) print k "=" v }' .env > .env.tmp
  mv .env.tmp .env
done
chmod 600 .env
docker compose up -d --force-recreate homepage >/dev/null 2>&1
echo OK
EOF
put "$TMP/apply.sh" /root/.dashboard-udm-apply.sh

URL=$(run "grep -m1 '^HOMEPAGE_VAR_UNIFI_URL=' $APP/.env | cut -d= -f2-" || true)
URL=${URL:-https://192.168.1.1}

say "UDM-API-Schlüssel eintragen ($WHERE)"
cat <<EOF
  So bekommst du den Schlüssel:
    1. UniFi Network öffnen: $URL
    2. Einstellungen -> Control Plane -> Integrations -> API-Schlüssel erstellen
    3. Schlüssel kopieren und hier einfügen (Rechtsklick -> Einfügen, Eingabe bleibt unsichtbar)

EOF

KEY=${UNIFI_KEY:-}
for _ in 1 2 3 4 5; do
  if [ -z "$KEY" ]; then
    [ -n "$HAVE_TTY" ] || fail "Keine Eingabe möglich (kein Terminal)."
    KEY=$(ask_secret 'API-Schlüssel')
  fi
  KEY=$(tr -d '[:space:]' <<<"$KEY")  # Leerzeichen/Zeilenumbrüche vom Kopieren entfernen
  [ -n "$KEY" ] || { warn "Nichts eingegeben."; [ -n "$HAVE_TTY" ] || break; continue; }
  printf '%s' "$KEY" > "$TMP/key"
  chmod 600 "$TMP/key"
  put "$TMP/key" /root/.dashboard-udm-key
  result=$(run "bash /root/.dashboard-udm-apply.sh '$APP' '$URL'" || true)
  case "$result" in
    OK)
      run "rm -f /root/.dashboard-udm-apply.sh"
      ok "Schlüssel funktioniert und ist gespeichert."
      ok "Dashboard neu gestartet. Die Heimnetz-Kachel zeigt ihre Werte nach dem Neuladen der Seite."
      exit 0 ;;
    000)
      warn "Unter $URL antwortet keine UDM."
      [ -n "$HAVE_TTY" ] || break
      ip=$(ask 'IP-Adresse der UDM' "${URL#https://}")
      URL="https://${ip#https://}" ;;
    *)
      warn "Die UDM lehnt den Schlüssel ab (HTTP $result). Bitte nochmal kopieren und einfügen."
      KEY=""
      [ -n "$HAVE_TTY" ] || break ;;
  esac
done
run "rm -f /root/.dashboard-udm-apply.sh /root/.dashboard-udm-key" || true
fail "Schlüssel wurde nicht gespeichert. Einfach nochmal versuchen."
