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
GUESTS=$TMP/proxmox-gaeste.yaml
{ qm list 2>/dev/null | awk 'NR > 1 { print $1, "qemu", $2 }'
  pct list 2>/dev/null | awk 'NR > 1 { print $1, "lxc", $NF }'
} | sort -n > "$TMP/guests.txt"
count=0
seen=" "
: > "$GUESTS"
while read -r id type name; do
  [ -n "$id" ] || continue
  [ "$count" -eq 0 ] && echo "- Proxmox-Gäste:" >> "$GUESTS"
  count=$((count + 1))
  label=$name
  case "$seen" in *" $name "*) label="$name ($id)" ;; esac
  seen="$seen$name "
  lname=$(tr '[:upper:]' '[:lower:]' <<<"$name")
  case "$lname" in  # übliche Kurznamen -> Icon-Name
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
  cat >> "$GUESTS" <<EOF
    - "$label":
        icon: $icon
        href: "https://$HOST_IP:8006/#v1:0:=$type%2F$id"
        description: "$kind $id"
        proxmoxNode: "$NODE"
        proxmoxVMID: $id
        proxmoxType: $type
EOF
done < "$TMP/guests.txt"
ok "$count VMs/Container gefunden"

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
