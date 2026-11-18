# Berwalt-Tech Dashboard

Ein Dashboard für den Heimserver auf Basis von [Homepage](https://gethomepage.dev) und [Glances](https://github.com/nicolargo/glances).
Auf einer Seite siehst du:

| Bereich | Was du siehst |
|---|---|
| **Leiste oben** | CPU-Last, RAM, freier Speicher, CPU-Temperatur, Betriebszeit, Datum/Uhrzeit, Suche |
| **Server-Leistung** | Live-Diagramme für CPU und RAM, Temperatur, Top-5-Prozesse, Docker-Container mit CPU/RAM, Systeminfo |
| **Netzwerk & Traffic** | Traffic rein/raus der Server-Netzwerkkarte (live), Internet-Traffic rein/raus über die FRITZ!Box, Verbindungsstatus, Festplatten-Lesen/Schreiben, Speicherplatz |
| **Meine Dienste** | Eine Kachel pro Dienst: Klick öffnet ihn. Grüner Punkt = erreichbar. Bei Docker-Diensten zusätzlich CPU/RAM/Traffic des Containers |

Für alle Details gibt es außerdem die Glances-Oberfläche unter `http://<SERVER-IP>:61208`.

## Voraussetzungen

- Ein **Linux-Rechner, der dauerhaft läuft** (Raspberry Pi, Mini-PC, NAS, Proxmox-VM …)
- **Docker** mit Compose-Plugin ([Anleitung](https://docs.docker.com/engine/install/)), kurz:
  ```bash
  curl -fsSL https://get.docker.com | sh
  ```

> **Windows-PC als Server?** Docker Desktop läuft dort in einer virtuellen Maschine, deshalb würde Glances nur die VM messen und nicht deinen PC. Lösung: den Dienst `glances` aus der `docker-compose.yml` löschen und Glances direkt unter Windows starten (`pip install "glances[web]"`, dann `glances -w`). Die übrige Einrichtung bleibt gleich.

## Installation

1. Repository auf den Server holen:
   ```bash
   git clone https://github.com/berwaltphilipp-tech/Berwalt-Tech.git
   cd Berwalt-Tech
   ```

2. Einstellungsdatei anlegen und anpassen:
   ```bash
   cp .env.example .env
   nano .env
   ```
   Wichtig sind vor allem:
   - `HOMEPAGE_ALLOWED_HOSTS` und `HOMEPAGE_VAR_SERVER_IP`: IP deines Servers (`hostname -I` zeigt sie)
   - `HOMEPAGE_VAR_NET_IFACE`: Netzwerkkarte (`ip -br link` zeigt sie, z. B. `eth0` oder `enp3s0`)
   - `HOMEPAGE_VAR_DISK`: Festplatte (`lsblk -d -o NAME` zeigt sie, z. B. `sda` oder `nvme0n1`)
   - `HOMEPAGE_VAR_FRITZBOX_URL`: Adresse der FRITZ!Box (Standard: `http://192.168.178.1`)

3. Starten:
   ```bash
   docker compose up -d
   ```

4. Im Browser öffnen: `http://<SERVER-IP>:3000`

## FRITZ!Box freischalten (für den Internet-Traffic)

In der FRITZ!Box-Oberfläche unter **Heimnetz → Netzwerk → Netzwerkeinstellungen** diese zwei Haken setzen:

- ☑ Zugriff für Anwendungen zulassen
- ☑ Statusinformationen über UPnP übertragen

Ein Passwort ist dafür nicht nötig. Wer eine andere Hardware hat, findet passende Widgets für OPNsense, pfSense, UniFi, OpenWrt oder MikroTik in der [Homepage-Doku](https://gethomepage.dev/widgets/).

## Eigene Dienste hinzufügen

**Variante A: in `config/services.yaml`.** Ganz unten steht eine Vorlage. Block kopieren, `#` entfernen und Name, Adresse und Icon anpassen. Die Icons findest du auf [dashboardicons.com](https://dashboardicons.com). Die Änderung erscheint nach einem Neuladen der Seite.

**Variante B: automatisch per Docker-Label.** Gib einem beliebigen Container diese Labels, dann taucht er von selbst auf dem Dashboard auf:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin
    labels:
      - homepage.group=Meine Dienste
      - homepage.name=Jellyfin
      - homepage.icon=jellyfin.svg
      - homepage.href=http://192.168.178.10:8096
      - homepage.description=Filme & Serien
```

Viele Dienste (Pi-hole, AdGuard, Proxmox, Jellyfin, Home Assistant …) können zusätzlich eigene Live-Werte auf ihrer Kachel zeigen, siehe [Widget-Liste](https://gethomepage.dev/widgets/).

## Aktualisieren

```bash
docker compose pull && docker compose up -d
```

## Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| Seite zeigt *"Host validation failed"* | Die Adresse aus der Browserzeile (inkl. `:3000`) in `HOMEPAGE_ALLOWED_HOSTS` eintragen, dann `docker compose up -d` |
| Glances-Kacheln zeigen *API-Fehler* | Prüfen, ob `http://<SERVER-IP>:61208` im Browser lädt. Bei aktiver Firewall (ufw) den Zugriff erlauben: `sudo ufw allow from 172.16.0.0/12 to any port 61208` |
| Server-Traffic bleibt leer | Falscher Name in `HOMEPAGE_VAR_NET_IFACE`. Alle Namen stehen unter `http://<SERVER-IP>:61208/api/4/network` |
| CPU-Temperatur zeigt `-` | Sensorname in `HOMEPAGE_VAR_CPU_SENSOR` anpassen. Alle Sensoren stehen unter `http://<SERVER-IP>:61208/api/4/sensors` (in virtuellen Maschinen gibt es oft keine) |
| FRITZ!Box-Kacheln zeigen *API-Fehler* | Die zwei Haken oben setzen und `HOMEPAGE_VAR_FRITZBOX_URL` prüfen |

Protokolle ansehen: `docker compose logs -f homepage`

## Sicherheit

- Das Dashboard ist für das **Heimnetz** gedacht. Port `3000` nicht im Router nach außen freigeben. Für Zugriff von unterwegs besser ein VPN nutzen (FRITZ!Box-VPN, WireGuard oder Tailscale).
- Glances (Port `61208`) ist im Heimnetz ohne Passwort erreichbar und zeigt nur Messwerte an.
- Docker ist für das Dashboard nur lesend über `dockerproxy` erreichbar.

## Dateien

```
docker-compose.yml   Startet Dashboard, Glances und Docker-Proxy
.env.example         Vorlage für deine Einstellungen (wird zu .env)
config/
  settings.yaml      Aussehen, Sprache, Aufteilung
  widgets.yaml       Leiste oben
  services.yaml      Alle Kacheln: Leistung, Traffic, Dienste
  docker.yaml        Verbindung zu Docker
  bookmarks.yaml     Lesezeichen unten
images/background.jpg  Hintergrundbild
```
