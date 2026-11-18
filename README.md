# Berwalt-Tech Dashboard

Ein Dashboard für den Proxmox-Heimserver auf Basis von [Homepage](https://gethomepage.dev) und [Glances](https://github.com/nicolargo/glances).
Auf einer Seite siehst du:

| Bereich | Was du siehst |
|---|---|
| **Leiste oben** | CPU-Last, RAM, CPU-Temperatur, Betriebszeit des Proxmox-Servers, Datum/Uhrzeit, Suche |
| **Internet & Heimnetz** | Internet-Traffic rein/raus (aktuell und gesamt) und Leitungsstatus von der FRITZ!Box, Betriebszeit und Anzahl der Geräte in LAN/WLAN von der UDM |
| **Server** | Live-Diagramme für CPU, RAM und Netzwerk-Traffic des Proxmox-Servers, Temperatur, Festplatte (Lesen/Schreiben), Systeminfo, laufende VMs/LXCs, **alle Proxmox-Speicher** (local, local-lvm, ZFS, NAS …) mit freiem Platz und Belegung |
| **Proxmox-Gäste** | Eine Kachel pro VM und LXC mit Status, CPU und RAM, wird automatisch erzeugt. Ein Klick öffnet **das Programm** darin (z. B. Home Assistant), nicht die VM |
| **Meine Dienste** | Proxmox, FRITZ!Box, UniFi, Glances und deine eigenen Dienste: Klick öffnet sie, grüner Punkt = erreichbar |

Für alle Details gibt es außerdem die Glances-Oberfläche unter `http://<PROXMOX-IP>:61208` und die UniFi-Oberfläche der UDM (Traffic je Gerät).

### Aufbau

```
Internet ── FRITZ!Box 6690 ── UDM ── Heimnetz
                                       │
                                       └── Proxmox-Server
                                             ├── Glances (direkt auf dem Host, misst alles)
                                             ├── LXC "dashboard" (Docker + Homepage, Port 3000)
                                             └── deine VMs und LXCs
```

- Die **FRITZ!Box** sieht jedes Byte, das ins Internet geht oder von dort kommt, deshalb kommt der Internet-Traffic von ihr.
- Die **UDM** liefert die Infos zum Heimnetz dahinter.
- **Glances** läuft direkt auf dem Proxmox-Host, weil es nur dort die echten Werte des Servers sieht (in einer VM würde es nur die VM messen). Der Traffic von `vmbr0` umfasst den Server samt aller VMs.
- **Proxmox** wird über einen Benutzer mit API-Token abgefragt, der **nur Leserechte** hat (Rolle `PVEAuditor`).

## Installation auf Proxmox

1. In der Proxmox-Oberfläche links deinen **Knoten** anklicken (z. B. `pve`), dann oben rechts auf **„>_ Shell“**.
2. Diese Zeile einfügen und Enter drücken:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/berwaltphilipp-tech/Berwalt-Tech/HEAD/proxmox-install.sh)"
   ```

3. Wenn danach gefragt wird, den API-Schlüssel der UDM einfügen (siehe [unten](#udm-freischalten-für-das-heimnetz)). Leer lassen geht auch, dann einfach später nochmal ausführen.

Das Skript braucht ein paar Minuten und erledigt:

- Glances auf dem Proxmox-Host installieren (in `/opt/glances`, als Dienst `glances`)
- Benutzer `homepage@pve` mit Lese-Token anlegen
- LXC-Container `dashboard` erstellen (Debian, 2 Kerne, 1,5 GB RAM, 8 GB Speicher, startet automatisch mit)
- darin Docker und das Dashboard installieren (`/opt/berwalt-tech`)
- Netzwerkkarte, Festplatte, CPU-Sensor, FRITZ!Box und UDM erkennen und prüfen
- für jede VM und jeden LXC eine Kachel anlegen und die Weboberfläche des Programms darin suchen (siehe [Kacheln der VMs und LXCs](#kacheln-der-vms-und-lxcs))

Am Ende zeigt es die Adresse des Dashboards (`http://<IP-DES-CONTAINERS>:3000`) und, falls nötig, was in FRITZ!Box oder UDM noch freizuschalten ist.

> **Tipp:** Gib dem Container `dashboard` in der UDM eine feste IP-Adresse, dann bleibt die Dashboard-Adresse immer gleich.

**Neue VM angelegt, etwas freigeschaltet oder Update gewünscht?** Einfach dieselbe Zeile nochmal in der Proxmox-Shell ausführen. Das Skript lässt sich beliebig oft starten, aktualisiert alles und übernimmt neue VMs/LXCs.

### Ohne Proxmox (beliebiger Linux-Server)

```bash
git clone https://github.com/berwaltphilipp-tech/Berwalt-Tech.git && cd Berwalt-Tech && sudo ./setup.sh
```

Dann läuft Glances als Docker-Container neben dem Dashboard. Die Proxmox-Kachel in `config/services.yaml` kannst du in dem Fall löschen.

## FRITZ!Box freischalten (für den Internet-Traffic)

In der FRITZ!Box-Oberfläche unter **Heimnetz → Netzwerk → Netzwerkeinstellungen** diese zwei Haken setzen:

- ☑ Zugriff für Anwendungen zulassen
- ☑ Statusinformationen über UPnP übertragen

Ein Passwort ist dafür nicht nötig.

## UDM freischalten (für das Heimnetz)

**Empfohlen: API-Schlüssel**

1. UniFi Network öffnen (z. B. `https://192.168.1.1`)
2. **Einstellungen → Control Plane → Integrations → API-Schlüssel erstellen**
3. Schlüssel kopieren und beim Installations-Skript einfügen

**Schlüssel nachtragen oder ändern:** In der Proxmox-Shell diese Zeile ausführen und den Schlüssel einfügen. Mehr ist nicht nötig:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/berwaltphilipp-tech/Berwalt-Tech/HEAD/udm-key.sh)"
```

Das Skript prüft den Schlüssel direkt an der UDM, speichert ihn und startet das Dashboard neu. Ist er falsch, fragt es nochmal. Ohne Proxmox: im Dashboard-Ordner `sudo ./udm-key.sh`.

**Alternative für ältere Firmware: lokaler Benutzer**

1. In UniFi OS unter **Admins & Users** einen neuen Admin anlegen
2. **Nur lokalen Zugriff erlauben** aktivieren und als Rolle für Network **Nur ansehen** (View Only) wählen
3. Im Container (`pct enter <ID>`) in `/opt/berwalt-tech/.env` bei `HOMEPAGE_VAR_UNIFI_USER` / `HOMEPAGE_VAR_UNIFI_PASS` eintragen

## Kacheln der VMs und LXCs

Ein Klick auf eine VM- oder LXC-Kachel öffnet direkt das Programm darin. Das Skript findet die Adresse so:

1. **Notiz in Proxmox:** Steht bei der VM/dem LXC unter *Übersicht → Notizen* eine Zeile wie `dashboard: http://192.168.1.20:8123`, wird genau diese Adresse benutzt. Mit nur einer IP (`dashboard: 192.168.1.20`) sucht das Skript dort selbst die Weboberfläche.
2. **Automatisch:** Es ermittelt die IP-Adresse (bei LXCs direkt, bei VMs über den QEMU-Gast-Agenten oder die MAC-Adresse) und sucht die Weboberfläche. Für über 40 bekannte Programme kennt es den Port (Home Assistant 8123, Jellyfin 8096, Plex, Pi-hole, Nextcloud, Immich, Paperless, Portainer, Proxmox Backup Server, *arr, …). Sonst probiert es die üblichen Web-Ports. Der Name der VM/des LXC hilft dabei, z. B. `homeassistant` oder `jellyfin`.
   Findet es die IP nicht, **fragt es dich beim Ausführen danach** und merkt sie sich. Leer lassen heißt „nicht mehr fragen“. Die Fragen kommen wieder, wenn du `/etc/berwalt-dashboard/gast-ips` auf dem Proxmox-Host löschst.
3. **Zuletzt gefunden:** Ist eine VM gerade aus, bleibt die zuletzt gefundene Adresse erhalten.
4. Findet es nichts, öffnet die Kachel die VM in Proxmox.

Am Ende zeigt das Skript eine Liste, welche Kachel wohin führt. Stimmt eine Adresse nicht oder fehlt sie: Notiz eintragen (Punkt 1) und das Skript nochmal ausführen.

> Läuft in einer VM mehr als ein Programm (z. B. ein Docker-Host), öffnet die Kachel das erste gefundene. Die übrigen Programme trägst du unter „Meine Dienste“ ein (siehe unten).

## Eigene Dienste hinzufügen

Die Dateien liegen im Container `dashboard` unter `/opt/berwalt-tech`. Hineinkommen: Proxmox-Shell → `pct enter <ID>`.

**Variante A: in `config/services.yaml`.** Ganz unten steht eine Vorlage. Block kopieren, `#` entfernen und Name, Adresse und Icon anpassen. Die Icons findest du auf [dashboardicons.com](https://dashboardicons.com). Die Änderung erscheint nach einem Neuladen der Seite.

> Den Block zwischen `# >>> proxmox-gaeste` und `# <<< proxmox-gaeste` nicht von Hand ändern, der wird bei jedem Lauf neu erzeugt.


**Variante B: automatisch per Docker-Label** (für Container, die im Dashboard-LXC laufen):

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin
    labels:
      - homepage.group=Meine Dienste
      - homepage.name=Jellyfin
      - homepage.icon=jellyfin.svg
      - homepage.href=http://192.168.1.20:8096
      - homepage.description=Filme & Serien
```

Viele Dienste (Pi-hole, AdGuard, Jellyfin, Home Assistant …) können zusätzlich eigene Live-Werte auf ihrer Kachel zeigen, siehe [Widget-Liste](https://gethomepage.dev/widgets/).

> Änderungen an `config/settings.yaml` (Aussehen, Reihenfolge, Spalten) und an der `.env` werden erst nach einem Neustart übernommen: `docker compose up -d --force-recreate homepage`

## Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| Seite zeigt *"Host validation failed"* | Die Adresse aus der Browserzeile (inkl. `:3000`) in `HOMEPAGE_ALLOWED_HOSTS` in der `.env` eintragen, dann `docker compose up -d --force-recreate homepage` |
| Server-Kacheln zeigen *API-Fehler* | Prüfen, ob `http://<PROXMOX-IP>:61208` im Browser lädt. Auf dem Host: `systemctl status glances`. Ist die Proxmox-Firewall aktiv, Port `61208` aus dem Heimnetz erlauben |
| Proxmox-Kacheln zeigen *API-Fehler* | Installations-Skript nochmal ausführen (erneuert den Token) |
| CPU-Temperatur zeigt `-` | Sensorname in `HOMEPAGE_VAR_CPU_SENSOR` anpassen. Alle Sensoren: `http://<PROXMOX-IP>:61208/api/4/sensors` |
| FRITZ!Box-Kacheln zeigen *API-Fehler* | Die zwei Haken oben setzen und Skript nochmal ausführen |
| UDM-Kachel zeigt *API-Fehler* | Schlüssel neu eintragen mit `udm-key.sh` (siehe [UDM freischalten](#udm-freischalten-für-das-heimnetz)) |
| `apt-get update` meldet 401-Fehler | Enterprise-Repository ohne Abo. Stört das Skript nicht, sonst in Proxmox unter *Updates → Repositories* das „No-Subscription“-Repository aktivieren |

Protokolle: im Container `cd /opt/berwalt-tech && docker compose logs -f homepage`, auf dem Host `journalctl -u glances`.

## Sicherheit

- Das Dashboard ist für das **Heimnetz** gedacht. Port `3000` nicht im Router nach außen freigeben. Für Zugriff von unterwegs besser ein VPN nutzen (FRITZ!Box-VPN, WireGuard oder Tailscale).
- Der Proxmox-Zugang `homepage@pve` kann **nur lesen** (Rolle `PVEAuditor`), aber nichts starten, stoppen oder ändern.
- Glances (Port `61208`) ist im Heimnetz ohne Passwort erreichbar und zeigt nur Messwerte an.
- API-Schlüssel und Token stehen nur in der `.env` im Container, lesbar nur für root.
- Falls Docker im LXC ohne Anpassung nicht startet, setzt das Skript für diesen einen Container das AppArmor-Profil auf `unconfined` (übliche Lösung für Docker in LXC). Der Container bleibt unprivilegiert.

## Wieder entfernen

In der Proxmox-Shell:

```bash
pct stop <ID> && pct destroy <ID>
```
```bash
systemctl disable --now glances && rm -rf /opt/glances /etc/glances /etc/systemd/system/glances.service /etc/berwalt-dashboard
```
```bash
pveum user delete homepage@pve
```

## Dateien

```
proxmox-install.sh   Einrichtung auf Proxmox (in der Proxmox-Shell ausführen)
setup.sh             Einrichtung auf einem Linux-Server bzw. im Dashboard-LXC
udm-key.sh           UDM-API-Schlüssel nachtragen oder ändern
docker-compose.yml   Startet Dashboard und Docker-Proxy (Glances optional)
.env.example         Vorlage für die Einstellungen (wird zu .env)
config/
  settings.yaml      Aussehen, Sprache, Aufteilung
  widgets.yaml       Leiste oben
  services.yaml      Alle Kacheln: Traffic, Server, Proxmox-Gäste, Dienste
  docker.yaml        Verbindung zu Docker
  bookmarks.yaml     Lesezeichen unten
images/background.jpg  Hintergrundbild
```
