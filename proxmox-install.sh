#!/usr/bin/env bash
# Berwalt-Tech Dashboard auf Proxmox VE einrichten.
#
# In der Proxmox-Oberfläche den Knoten anklicken -> ">_ Shell" und einfügen:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/berwaltphilipp-tech/Berwalt-Tech/HEAD/proxmox-install.sh)"
#
# Was passiert:
#   1. Glances wird direkt auf dem Proxmox-Host installiert. Es misst CPU, RAM,
#      Temperatur, Festplatten und den Traffic des Servers inkl. aller VMs.
#   2. Ein Proxmox-Benutzer "homepage@pve" mit API-Token NUR MIT LESERECHTEN wird angelegt.
#   3. Ein kleiner LXC-Container "dashboard" (Debian + Docker) wird erstellt.
#   4. Darin wird das Dashboard installiert, mit einer Kachel für jede VM und jeden LXC.
#
# Kann gefahrlos mehrfach ausgeführt werden: aktualisiert dann alles und
# übernimmt neu angelegte VMs/LXCs ins Dashboard.
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/berwaltphilipp-tech/Berwalt-Tech.git}
CT_NAME=dashboard
APP_DIR=/opt/berwalt-tech
ICON_CDN=https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg
ONE_LINER='bash -c "$(curl -fsSL https://raw.githubusercontent.com/berwaltphilipp-tech/Berwalt-Tech/HEAD/proxmox-install.sh)"'
UDM_KEY_LINER='bash -c "$(curl -fsSL https://raw.githubusercontent.com/berwaltphilipp-tech/Berwalt-Tech/HEAD/udm-key.sh)"'

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$*"; exit 1; }

HAVE_TTY=""
if (exec </dev/tty >/dev/tty) 2>/dev/null; then HAVE_TTY=1; fi
ask_secret() {
  local answer=""
  if [ -n "$HAVE_TTY" ]; then
    printf '  %s: ' "$1" >/dev/tty
    read -r -s answer </dev/tty || true
    echo >/dev/tty
  fi
  printf '%s' "$answer"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" -eq 0 ] || fail "Bitte als root in der Proxmox-Shell ausführen."
command -v pveversion >/dev/null || fail "Dieses Skript läuft nur direkt auf einem Proxmox-VE-Host."
ok "$(pveversion)"

# ------------------------------------------------------------------------------
say "1/5  Proxmox-Host erkennen"
IFACE="" HOST_IP=""
IFS=";" read -r _ IFACE HOST_IP < <(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
  for (i = 1; i <= NF; i++) { if ($i == "via") g = $(i+1); if ($i == "dev") d = $(i+1); if ($i == "src") s = $(i+1) }
} END { print g ";" d ";" s }') || true
[ -n "$HOST_IP" ] || fail "Keine IP-Adresse des Hosts gefunden."
NODE=$(hostname)
case "$IFACE" in vmbr*) BRIDGE=$IFACE ;; *) BRIDGE=vmbr0 ;; esac
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
DISK=$(lsblk -rsno NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2 == "disk" { print $1; exit }' || true)
[ -n "$DISK" ] || DISK=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 !~ /^(loop|zram|ram|zd)/ { print $1; exit }' || true)
DISK=${DISK:-sda}
ok "Knoten:        $NODE"
ok "Host-IP:       $HOST_IP"
ok "Netzwerk:      $IFACE (Bridge für den Container: $BRIDGE)"
ok "Festplatte:    $DISK"

# ------------------------------------------------------------------------------
say "2/5  Glances auf dem Host (Messwerte)"
if [ ! -x /opt/glances/bin/glances ]; then
  if ! python3 -c 'import ensurepip' 2>/dev/null; then
    apt-get update -qq || warn "apt-get update meldet Fehler (z. B. Enterprise-Repo ohne Abo), versuche trotzdem weiter"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null
  fi
  python3 -m venv /opt/glances
fi
/opt/glances/bin/pip install -q --disable-pip-version-check --upgrade 'glances[web]'
mkdir -p /etc/glances
cat > /etc/glances/glances.conf <<'EOF'
# Automatisch erzeugt von proxmox-install.sh
[global]
check_update=false

[fs]
hide=/boot.*,.*/snap.*
# ZFS-Dateisysteme (Proxmox-Standard) mit anzeigen
allow=zfs
EOF
cat > /etc/systemd/system/glances.service <<'EOF'
[Unit]
Description=Glances (Messwerte für das Berwalt-Tech Dashboard)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/opt/glances/bin/glances -C /etc/glances/glances.conf -w
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable glances >/dev/null 2>&1
systemctl restart glances
for _ in $(seq 1 30); do
  curl --noproxy '*' -s -m 2 -o /dev/null http://127.0.0.1:61208/api/4/status && break
  sleep 2
done
curl --noproxy '*' -s -m 2 -o /dev/null http://127.0.0.1:61208/api/4/status || fail "Glances startet nicht. Details: journalctl -u glances"
ok "Glances läuft: http://$HOST_IP:61208"

# ------------------------------------------------------------------------------
say "3/5  Proxmox-Zugang nur mit Leserechten"
pveum user add homepage@pve --comment "Berwalt-Tech Dashboard (nur lesen)" >/dev/null 2>&1 || true
pveum acl modify / --users homepage@pve --roles PVEAuditor
pveum user token remove homepage@pve dashboard >/dev/null 2>&1 || true
TOKEN_JSON=$(pveum user token add homepage@pve dashboard --privsep 0 --comment "Berwalt-Tech Dashboard" --output-format json)
TOKEN_SECRET=$(grep -o '"value" *: *"[^"]*"' <<<"$TOKEN_JSON" | cut -d'"' -f4)
[ -n "$TOKEN_SECRET" ] || fail "API-Token konnte nicht angelegt werden."
TOKEN_ID='homepage@pve!dashboard'
ok "Benutzer homepage@pve mit Rolle PVEAuditor (nur lesen), Token erneuert"

# ------------------------------------------------------------------------------
say "4/5  LXC-Container \"$CT_NAME\""
CTID=$(pct list | awk -v n="$CT_NAME" 'NR > 1 && $NF == n { print $1 }' | head -1 || true)
if [ -z "$CTID" ]; then
  pveam update >/dev/null || warn "Vorlagenliste konnte nicht aktualisiert werden"
  TSTORE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }' | head -1 || true)
  RSTORE=$(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }' | head -1 || true)
  { [ -n "$TSTORE" ] && [ -n "$RSTORE" ]; } || fail "Kein Speicher für Vorlagen bzw. Container gefunden."
  TEMPLATE=""
  for v in 12 13; do
    TEMPLATE=$(pveam available --section system | awk '{ print $2 }' | grep -E "^debian-$v-standard_" | sort -V | tail -1 || true)
    [ -n "$TEMPLATE" ] && break
  done
  [ -n "$TEMPLATE" ] || fail "Keine Debian-Vorlage gefunden (pveam available)."
  if ! pveam list "$TSTORE" | grep -F "$TEMPLATE" >/dev/null; then
    echo "  Lade Vorlage $TEMPLATE ..."
    pveam download "$TSTORE" "$TEMPLATE" >/dev/null
  fi
  CTID=$(pvesh get /cluster/nextid)
  pct create "$CTID" "$TSTORE:vztmpl/$TEMPLATE" \
    --hostname "$CT_NAME" --description "Berwalt-Tech Dashboard" \
    --cores 2 --memory 1536 --swap 512 --rootfs "$RSTORE:8" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
    --features nesting=1,keyctl=1 --unprivileged 1 --onboot 1 --ostype debian >/dev/null
  ok "Container $CTID angelegt (2 Kerne, 1,5 GB RAM, 8 GB Speicher)"
fi
[[ "$(pct status "$CTID")" == *running* ]] || pct start "$CTID"

wait_for_ip() {
  CT_IP=""
  for _ in $(seq 1 60); do
    CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{ print $1 }' || true)
    [ -n "$CT_IP" ] && return 0
    sleep 2
  done
  fail "Container $CTID bekommt keine IP-Adresse (DHCP der UDM prüfen)."
}
wait_for_ip
ok "Container $CTID läuft: $CT_IP"

ctx() { pct exec "$CTID" -- bash -c "$1"; }
ctx 'command -v git >/dev/null && command -v curl >/dev/null || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl git ca-certificates >/dev/null; }'
ctx 'command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; }'
if ! ctx 'docker run --rm hello-world >/dev/null 2>&1'; then
  # Bekanntes Problem bei Docker in LXC (AppArmor): Container entsprechend freigeben
  warn "Docker braucht im Container eine Freigabe, wird eingerichtet"
  CONF=/etc/pve/lxc/$CTID.conf
  grep -q '^lxc.apparmor.profile' "$CONF" || echo 'lxc.apparmor.profile: unconfined' >> "$CONF"
  grep -q 'apparmor/parameters/enabled' "$CONF" || echo 'lxc.mount.entry: /dev/null sys/module/apparmor/parameters/enabled none bind 0 0' >> "$CONF"
  pct reboot "$CTID"
  wait_for_ip
  ctx 'docker run --rm hello-world >/dev/null 2>&1' || fail "Docker startet im Container nicht. Details: pct enter $CTID, dann: docker run hello-world"
fi
ok "Docker läuft im Container"

if ! ctx "curl --noproxy '*' -s -m 3 -o /dev/null http://$HOST_IP:61208/api/4/status"; then
  warn "Der Container erreicht Glances auf dem Host nicht (Port 61208)."
  warn "Ist die Proxmox-Firewall aktiv? Dann Port 61208 aus dem Heimnetz erlauben."
fi

# Dashboard holen bzw. aktualisieren. Den automatisch erzeugten Gäste-Block vorher
# leeren, damit sich die Aktualisierung nicht mit ihm in die Quere kommt.
ctx "if [ -d $APP_DIR/.git ]; then
  cd $APP_DIR
  awk '/^# >>> proxmox-gaeste/ { print; skip = 1; next } /^# <<< proxmox-gaeste/ { skip = 0 } !skip' config/services.yaml > config/services.yaml.tmp && mv config/services.yaml.tmp config/services.yaml
  git pull -q --ff-only || echo '  ! Aktualisierung übersprungen (eigene Änderungen in den Dateien)'
else
  git clone -q $REPO_URL $APP_DIR
fi"
ok "Dashboard-Dateien in $APP_DIR"

# ------------------------------------------------------------------------------
say "5/5  Kacheln für alle VMs und Container erzeugen"
# Ziel: Ein Klick auf eine Kachel öffnet das Programm in der VM/im LXC,
# nicht die VM in Proxmox. Reihenfolge, um die Adresse zu finden:
#   1. Notiz in Proxmox mit einer Zeile "dashboard: http://IP:PORT"
#   2. automatisch: IP des Gasts ermitteln und den Web-Port des Programms suchen
#   3. zuletzt gefundene Adresse (falls der Gast gerade aus ist)
#   4. sonst: öffnet den Gast in Proxmox
GUESTS=$TMP/proxmox-gaeste.yaml
STATE_DIR=/etc/berwalt-dashboard
mkdir -p "$STATE_DIR"
CACHE=$STATE_DIR/gast-adressen
IPS=$STATE_DIR/gast-ips  # von Hand eingegebene IPs ("-" = nicht mehr fragen)
touch "$CACHE" "$IPS"
: > "$TMP/cache.new"
NET_BASE=${HOST_IP%.*}
HOST_CIDR=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{ print $4 }' | head -1 || true)

{ qm list 2>/dev/null | awk 'NR > 1 { print $1, "qemu", $3, $2 }'
  pct list 2>/dev/null | awk 'NR > 1 { print $1, "lxc", $2, $NF }'
} | sort -n > "$TMP/guests.txt"

# Aus einer Liste von IPs (eine pro Zeile) die passende wählen: bevorzugt das
# Heimnetz des Hosts, keine Loopback-/Docker-internen Adressen.
pick_ip() {
  local ips
  ips=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(127\.|169\.254\.|172\.(1[7-9]|2[0-9]|3[01])\.)' || true)
  [ -n "$ips" ] || return 0
  grep -m1 -F "$NET_BASE." <<<"$ips" || head -1 <<<"$ips"
}

guest_ip() {  # $1 = ID, $2 = qemu|lxc
  local id=$1 type=$2 ip="" mac
  if [ "$type" = lxc ]; then
    lxc-info -n "$id" -iH </dev/null 2>/dev/null | pick_ip
    return 0
  fi
  if qm config "$id" </dev/null 2>/dev/null | grep -qE '^agent: *(1|enabled=1)'; then
    ip=$(timeout 8 qm guest cmd "$id" network-get-interfaces </dev/null 2>/dev/null \
      | grep -oE '"ip-address" *: *"[0-9.]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | pick_ip || true)
  fi
  if [ -z "$ip" ]; then  # ohne Gast-Agent: MAC-Adresse der VM in der ARP-Tabelle des Hosts suchen
    mac=$(qm config "$id" </dev/null 2>/dev/null | grep -E '^net[0-9]+:' | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 || true)
    [ -n "$mac" ] && ip=$(ip -4 neigh show 2>/dev/null | grep -i " $mac " | awk '{ print $1 }' | pick_ip || true)
  fi
  printf '%s' "$ip"
}

# Sucht die Weboberfläche: zuerst die bekannten Ports des Programms, dann übliche Web-Ports.
probe_url() {  # $1 = IP, $2 = Programmname
  local ip=$1 cands="" c proto rest port path code code2 url
  case "$2" in
    home-assistant) cands="http:8123 https:8123" ;;
    jellyfin|emby) cands="http:8096 https:8920" ;;
    plex) cands="http:32400/web" ;;
    pi-hole) cands="http:80/admin https:443/admin" ;;
    adguard-home) cands="http:80 http:3000" ;;
    nextcloud|vaultwarden|truenas|openmediavault|omv) cands="https:443 http:80" ;;
    immich) cands="http:2283" ;;
    paperless*) cands="http:8000 http:8010" ;;
    wireguard|wg-easy) cands="http:51821" ;;
    portainer|docker*) cands="https:9443 http:9000" ;;
    nginx-proxy-manager) cands="http:81" ;;
    uptime-kuma|uptimekuma) cands="http:3001" ;;
    grafana|gitea|forgejo) cands="http:3000" ;;
    proxmox-backup-server) cands="https:8007" ;;
    frigate) cands="http:5000 https:8971" ;;
    node-red|nodered) cands="http:1880" ;;
    n8n) cands="http:5678" ;;
    zigbee2mqtt) cands="http:8080" ;;
    esphome) cands="http:6052" ;;
    audiobookshelf) cands="http:13378 http:80" ;;
    sonarr) cands="http:8989" ;;
    radarr) cands="http:7878" ;;
    prowlarr) cands="http:9696" ;;
    lidarr) cands="http:8686" ;;
    bazarr) cands="http:6767" ;;
    readarr) cands="http:8787" ;;
    qbittorrent) cands="http:8090 http:8080" ;;
    sabnzbd) cands="http:7777 http:8080" ;;
    overseerr|jellyseerr) cands="http:5055" ;;
    tautulli) cands="http:8181" ;;
    syncthing) cands="http:8384" ;;
    homarr) cands="http:7575" ;;
    unifi*) cands="https:8443" ;;
    omada) cands="https:8043" ;;
    cockpit) cands="https:9090" ;;
    dashboard) cands="http:3000" ;;
  esac
  for c in $cands http:80 https:443 http:8080 https:8443 http:3000 http:8000 http:5000 http:9000 https:9443 http:8081; do
    proto=${c%%:*}; rest=${c#*:}; port=${rest%%/*}; path=""
    [ "$rest" != "$port" ] && path="/${rest#*/}"
    code=$(curl --noproxy '*' -sk -o /dev/null --connect-timeout 2 -m 4 -w '%{http_code}' "$proto://$ip:$port$path" 2>/dev/null || true)
    if [ "$proto" = http ] && [ "$code" = 400 ]; then  # Antwort "400" auf HTTP: oft ein HTTPS-Port
      code2=$(curl --noproxy '*' -sk -o /dev/null --connect-timeout 2 -m 4 -w '%{http_code}' "https://$ip:$port$path" 2>/dev/null || true)
      [ -n "$code2" ] && [ "$code2" != 000 ] && proto=https && code=$code2
    fi
    # 000 = keine Antwort, 404 = Server ohne Weboberfläche (z. B. reine APIs/MCP-Server)
    if [ -n "$code" ] && [ "$code" != 000 ] && [ "$code" != 404 ]; then
      url="$proto://$ip"
      case "$proto:$port" in http:80|https:443) ;; *) url="$url:$port" ;; esac
      printf '%s' "$url$path"
      return 0
    fi
  done
}

# $1 = ID, $2 = qemu|lxc -> Eintrag aus der Proxmox-Notiz: "dashboard: http://..."
# oder "dashboard: 192.168.1.20" (dann wird dort die Weboberfläche gesucht)
notes_value() {
  pvesh get "/nodes/$NODE/$2/$1/config" --output-format json </dev/null 2>/dev/null \
    | grep -oiE 'dashboard: *(https?://[^" \\<]+|[0-9]+(\.[0-9]+){3}(:[0-9]+)?)' | head -1 | sed -E 's/^[^:]+: *//' || true
}
ask() {  # sichtbare Eingabe, leer ohne Terminal
  local answer=""
  if [ -n "$HAVE_TTY" ]; then
    printf '  %s: ' "$1" >/dev/tty
    read -r answer </dev/tty || true
  fi
  printf '%s' "$answer"
}

# VMs ohne Gast-Agent findet man über die ARP-Tabelle; ein kurzer Ping an das
# Heimnetz (/24) füllt sie, falls nötig.
if grep -q ' qemu running ' "$TMP/guests.txt" && command -v ping >/dev/null && [ "${HOST_CIDR#*/}" = 24 ]; then
  for i in $(seq 1 254); do ping -c1 -W1 "$NET_BASE.$i" >/dev/null 2>&1 & done
  wait
fi

count=0
seen=" "
: > "$GUESTS"
: > "$TMP/report.txt"
while read -r id type state name <&3; do
  [ -n "$id" ] || continue
  [ "$count" -eq 0 ] && echo "- Proxmox-Gäste:" >> "$GUESTS"
  count=$((count + 1))
  label=$name
  case "$seen" in *" $name "*) label="$name ($id)" ;; esac
  seen="$seen$name "
  lname=$(tr '[:upper:]' '[:lower:]' <<<"$name")
  case "$lname" in  # übliche Kurznamen -> Programm-/Icon-Name
    homeassistant|hass|haos) lname=home-assistant ;;
    pihole) lname=pi-hole ;;
    adguard|adguardhome) lname=adguard-home ;;
    npm|nginxproxymanager) lname=nginx-proxy-manager ;;
    pbs|proxmoxbackupserver) lname=proxmox-backup-server ;;
    truenas-scale|truenasscale) lname=truenas ;;
  esac
  if curl -sfI -m 3 "$ICON_CDN/$lname.svg" >/dev/null 2>&1; then
    icon="$lname.svg"
  elif [ "$type" = qemu ]; then
    icon=mdi-monitor
  else
    icon=mdi-cube-outline
  fi
  if [ "$type" = qemu ]; then kind=VM; else kind=LXC; fi

  gip="" desc="" url="" how=""
  note=$(notes_value "$id" "$type")
  case "$note" in
    http://*|https://*) url=$note; how="aus der Proxmox-Notiz" ;;
    *:*) url="http://$note"; how="aus der Proxmox-Notiz" ;;
    ?*) gip=$note; how="IP aus der Proxmox-Notiz" ;;  # nur IP: Weboberfläche dort suchen
  esac
  if [ -z "$url" ] && [ "$id" = "$CTID" ]; then  # das Dashboard selbst
    url="http://$CT_IP:3000"; how="dieses Dashboard"
  fi
  if [ -z "$url" ]; then  # Programme, die online verwaltet werden
    case "$lname" in
      tailscale*) url="https://login.tailscale.com/admin/machines"; desc="Verwaltung bei Tailscale" ;;
      cloudflared*|cloudflare*) url="https://one.dash.cloudflare.com/"; desc="Verwaltung bei Cloudflare" ;;
      netbird*) url="https://app.netbird.io/"; desc="Verwaltung bei NetBird" ;;
    esac
    [ -n "$url" ] && how="Online-Verwaltung"
  fi
  if [ -z "$url" ] && [ "$state" = running ]; then
    [ -n "$gip" ] || gip=$(guest_ip "$id" "$type")
    if [ -z "$gip" ]; then  # nicht automatisch gefunden: gespeicherte oder erfragte IP
      saved=$(awk -v id="$id" '$1 == id { print $2 }' "$IPS" | tail -1 || true)
      if [ -n "$saved" ] && [ "$saved" != "-" ]; then
        gip=$saved
      elif [ -z "$saved" ] && [ -n "$HAVE_TTY" ]; then
        [ -n "${ASKED:-}" ] || { echo; echo "  Bei diesen Gästen wurde keine IP-Adresse gefunden. Du kannst sie hier eintragen:"; ASKED=1; }
        answer=$(ask "IP-Adresse von $label ($kind $id), leer = nicht mehr fragen")
        answer=$(tr -d '[:space:]' <<<"$answer")
        if [[ "$answer" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          gip=$answer
          echo "$id $answer" >> "$IPS"
        else
          [ -n "$answer" ] && warn "\"$answer\" ist keine IP-Adresse, übersprungen"
          echo "$id -" >> "$IPS"
        fi
      fi
      [ -n "$gip" ] && how="von Hand eingetragene IP"
    fi
    if [ -n "$gip" ]; then url=$(probe_url "$gip" "$lname"); how=${how:-automatisch gefunden}; fi
  else
    gip=""  # Gast ist aus: nichts zu prüfen, gespeicherte Adresse verwenden
  fi
  # Gespeicherte Adresse nur, wenn gerade nichts geprüft werden konnte (Gast aus
  # oder IP unbekannt); läuft der Gast und hat keine Weboberfläche, gilt sie nicht mehr.
  if [ -z "$url" ] && [ -z "$gip" ]; then
    url=$(awk -v id="$id" '$1 == id { print $2 }' "$CACHE"); how="zuletzt gefunden"
  fi

  if [ -n "$url" ]; then
    echo "$id $url" >> "$TMP/cache.new"
    href=$url
    desc=${desc:-${url#*://}}
    printf '  ✓ %-20s → %s (%s)\n' "$label" "$url" "$how" >> "$TMP/report.txt"
  else
    href="https://$HOST_IP:8006/#v1:0:=$type%2F$id"
    desc="$kind $id"
    if [ "$state" = running ] && [ -n "$gip" ]; then
      printf '  ! %-20s → läuft auf %s, aber keine Weboberfläche gefunden, öffnet Proxmox\n' "$label" "$gip" >> "$TMP/report.txt"
    elif [ "$state" = running ] && [ "$type" = qemu ]; then
      printf '  ! %-20s → IP-Adresse nicht gefunden (QEMU-Gast-Agent fehlt?), öffnet Proxmox\n' "$label" >> "$TMP/report.txt"
    elif [ "$state" = running ]; then
      printf '  ! %-20s → IP-Adresse nicht gefunden, öffnet Proxmox\n' "$label" >> "$TMP/report.txt"
    else
      printf '  - %-20s → ist aus, öffnet Proxmox\n' "$label" >> "$TMP/report.txt"
    fi
  fi
  cat >> "$GUESTS" <<EOF
    - "$label":
        icon: $icon
        href: "$href"
        description: "$desc"
        proxmoxNode: "$NODE"
        proxmoxVMID: $id
        proxmoxType: $type
EOF
done 3< "$TMP/guests.txt"
mv "$TMP/cache.new" "$CACHE"
ok "$count VMs/Container gefunden:"
cat "$TMP/report.txt"
if grep -q '^  [!-]' "$TMP/report.txt"; then
  echo
  echo "  Adresse von Hand festlegen: In Proxmox die VM/den LXC anklicken -> Übersicht ->"
  echo "  Notizen -> eine Zeile wie  dashboard: http://192.168.1.20:8123  (oder nur"
  echo "  dashboard: 192.168.1.20) eintragen, dann dieses Skript nochmal ausführen."
  echo "  Übersprungene IP-Fragen kommen wieder, wenn du $IPS löschst."
  if grep -q 'Gast-Agent fehlt' "$TMP/report.txt"; then
    echo
    echo "  VMs ohne IP: In der VM den Gast-Agenten installieren (Debian/Ubuntu:"
    echo "  apt install qemu-guest-agent) und in Proxmox unter Optionen -> QEMU Guest Agent aktivieren."
  fi
fi

# UDM-Schlüssel nur abfragen, wenn im Dashboard noch keiner hinterlegt ist
UNIFI_KEY=${UNIFI_KEY:-}
if [ -z "$UNIFI_KEY" ] && ! ctx "grep -qs '^HOMEPAGE_VAR_UNIFI_KEY=.' $APP_DIR/.env"; then
  echo
  echo "  Für die Heimnetz-Kachel braucht das Dashboard einen API-Schlüssel der UDM:"
  echo "  UniFi Network -> Einstellungen -> Control Plane -> Integrations -> API-Schlüssel erstellen"
  UNIFI_KEY=$(ask_secret 'API-Schlüssel einfügen (leer = später)')
fi

# Werte an das Einrichtungs-Skript im Container übergeben (Datei nur für root lesbar)
ENVF=$TMP/dashboard-install.env
{
  printf 'GLANCES_URL=%q\n' "http://$HOST_IP:61208"
  printf 'NET_IFACE=%q\n' "$IFACE"
  printf 'DISK_NAME=%q\n' "$DISK"
  printf 'ROOTFS=%q\n' "/"
  printf 'PVE_URL=%q\n' "https://$HOST_IP:8006"
  printf 'PVE_NODE=%q\n' "$NODE"
  printf 'PVE_TOKEN_ID=%q\n' "$TOKEN_ID"
  printf 'PVE_TOKEN_SECRET=%q\n' "$TOKEN_SECRET"
  printf 'GUESTS_FILE=%q\n' "/root/proxmox-gaeste.yaml"
  printf 'RERUN_HINT=%q\n' "$ONE_LINER (in der Proxmox-Shell)"
  printf 'UDM_KEY_HINT=%q\n' "$UDM_KEY_LINER (in der Proxmox-Shell)"
  [ -n "$UNIFI_KEY" ] && printf 'UNIFI_KEY=%q\n' "$UNIFI_KEY"
  [ -n "${FRITZBOX_IP:-}" ] && printf 'FRITZBOX_IP=%q\n' "$FRITZBOX_IP"
  [ -n "${UNIFI_IP:-}" ] && printf 'UNIFI_IP=%q\n' "$UNIFI_IP"
  true
} > "$ENVF"
chmod 600 "$ENVF"
pct push "$CTID" "$ENVF" /root/dashboard-install.env --perms 600
pct push "$CTID" "$GUESTS" /root/proxmox-gaeste.yaml

say "Dashboard im Container einrichten"
ctx "set -a; . /root/dashboard-install.env; set +a
rm -f /root/dashboard-install.env
$APP_DIR/setup.sh"

cat <<EOF

  Tipp: Gib dem Container "$CT_NAME" (ID $CTID) in der UDM eine feste IP-Adresse,
  dann bleibt die Dashboard-Adresse http://$CT_IP:3000 immer gleich.

EOF
