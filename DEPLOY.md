# Deployment Guide — Home Server

Vollständige Anleitung zur Erstinstallation und Verwaltung der Home-Lab-Infrastruktur.

---

## Übersicht

| Maschine        | IP               | Rolle                                          |
|-----------------|------------------|------------------------------------------------|
| `homeserver`    | 192.168.178.94   | k3s + ArgoCD + Semaphore (Kubernetes-Stack)    |
| `worker-0`      | 192.168.178.95   | Docker Compose (Paperless, TinyTeller, etc.)   |

---

## Voraussetzungen

### Lokale Workstation

```bash
# Ansible und Abhängigkeiten
pip install ansible

# Optional: Vault-Passwort-Datei anlegen (statt --ask-vault-pass bei jedem Aufruf)
echo 'DEIN_VAULT_PASSWORT' > ~/.vault_pass
chmod 600 ~/.vault_pass
export VAULT_OPTS="--vault-password-file=$HOME/.vault_pass"
```

### Beide Zielserver (Ubuntu 26.04 LTS)

Auf **jedem** Server einmalig ausführen:

```bash
# SSH-Zugang sicherstellen
ssh-copy-id ubuntu@192.168.178.94
ssh-copy-id ubuntu@192.168.178.95

# SSH-Verbindung testen
ansible -i ansible/inventory/hosts.yml all -m ping
```

---

## Schritt 1 — Repo klonen & Abhängigkeiten installieren

```bash
git clone https://github.com/D-PEKR/Home-Lab.git
cd Home-Lab
make deps
```

---

## Schritt 2 — Secrets anlegen (Ansible Vault)

### 2.1 — homeserver (k3s-Stack)

Alle Secrets leben in `ansible/group_vars/all.yml`. Datei öffnen:

```bash
make vault-edit
```

Folgende Werte **müssen** gesetzt werden (vault-verschlüsselt!):

| Variable | Beschreibung |
|---|---|
| `tailscale_auth_key` | Tailscale Auth-Key (Login → Settings → Keys) |
| `semaphore_vault_password` | Ansible-Vault-Passwort für Semaphore-Runs |
| `scanner_smb_password` | SMB-Passwort für den Paperless-Consume-Share |
| `scanner_gotify_token` | Gotify App-Token für Scanner-Benachrichtigungen |

Wert verschlüsseln und einfügen:

```bash
ansible-vault encrypt_string 'DEIN_WERT' --name 'variable_name'
# Ergebnis in group_vars/all.yml einfügen
```

### 2.2 — worker-0 (Docker Compose)

Vault-Datei für worker-0 befüllen:

```bash
# Die Datei existiert bereits — mit make vault-edit öffnen oder direkt editieren:
# ansible/host_vars/homeserver2/vault.yml
```

Secrets verschlüsseln und einfügen:

```bash
# sudo-Passwort für worker-0
ansible-vault encrypt_string 'SUDO_PASSWORT' --name 'vault_worker-0_become_password'

# TinyTeller / Day Pilot spezifische Secrets (falls nötig)
ansible-vault encrypt_string 'API_KEY' --name 'vault_day_pilot_openai_api_key'
```

Ergebnisse in `ansible/host_vars/homeserver2/vault.yml` einfügen.

> **Wichtig:** `vault.yml` niemals committen — sie liegt bereits in `.gitignore`.

---

## Schritt 3 — homeserver provisionieren (k3s-Stack)

```bash
# Vollständige Erstinstallation
make install

# Nur einzelne Rollen ausführen (z.B. nach Änderungen)
make common       # Basis-OS, Firewall, Pakete
make dnsmasq      # Split-DNS (*.homeserver)
make tailscale    # VPN
make k3s          # Kubernetes + Helm
make argocd       # GitOps-Controller
make semaphore    # Semaphore Secrets
```

Nach dem Durchlauf ist ArgoCD aktiv und synct `argocd/apps/` automatisch.

### Zugangsdaten ArgoCD

```bash
# Admin-Passwort abrufen
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n argocd get secret argocd-initial-admin-secret \
   -o jsonpath="{.data.password}" | base64 -d; echo'
```

ArgoCD UI: **http://192.168.178.94:30080** (Benutzer: `admin`)

---

## Schritt 4 — worker-0 provisionieren (k3s-Agent + Docker Compose)

```bash
# Dry-run zuerst
make worker-0-check

# Vollständige Installation (k3s-Agent + TinyTeller + Day Pilot)
make worker-0

# Nur k3s-Agent beitreten lassen
make k3s-agent

# Einzelne Docker-Compose-Dienste deployen
ansible-playbook -i ansible/inventory/hosts.yml ansible/homeserver2.yml \
  --tags tinyteller $(VAULT_OPTS)

ansible-playbook -i ansible/inventory/hosts.yml ansible/homeserver2.yml \
  --tags day-pilot $(VAULT_OPTS)
```

---

## Schritt 5 — Semaphore einrichten (Automatisierungs-UI)

Semaphore wird über ArgoCD deployed (nach Step 3). Sobald der Pod läuft:

```bash
# SSH-Key auf alle Targets verteilen (homeserver + worker-0)
make semaphore-targets

# Projekte / Inventories / Templates via API provisionieren
make semaphore-bootstrap
```

Semaphore UI: **http://semaphore.homeserver**

Folgende Projekte werden automatisch angelegt:

| Projekt | Playbook | Inventory |
|---|---|---|
| `home-server` | `ansible/site.yml` | homeserver (192.168.178.94) |
| `worker-0`    | `ansible/worker-0.yml` | worker-0 (192.168.178.95) |

Beide laufen täglich um 06:00 Uhr automatisch durch.

---

## Schritt 6 — Monitoring verifizieren

Nach dem ArgoCD-Sync (ca. 3 Minuten nach Push):

```bash
# Grafana Admin-Passwort
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n monitoring get secret monitoring-grafana \
   -o jsonpath="{.data.admin-password}" | base64 -d; echo'
```

Grafana: **http://grafana.homeserver** (Benutzer: `admin`)

Das Monitoring scrapt automatisch:
- `homeserver` — Node Exporter (DaemonSet im Cluster)
- Alle Pods/Services mit `VMServiceScrape`/`VMPodScrape`-Annotationen

---

## Schritt 7 — Single Sign-On (SSO) einrichten

Nach dem automatischen ArgoCD-Sync von `argocd/apps/authentik/` steht Authentik als zentraler Identity Provider bereit.

**Voraussetzung:** Secrets müssen zuerst mit `kubeseal` versiegelt und in `values.yaml` eingetragen werden (Anleitung: [docs/14-sso-authentik.md](docs/14-sso-authentik.md)).

```bash
# 1. Sealed-Werte erzeugen und in values.yaml eintragen (Einmalaufwand)
#    → Anleitung: docs/14-sso-authentik.md, Abschnitt "Schritt 1"

# 2. Authentik-Status prüfen (ArgoCD synct automatisch nach Push)
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik get pods'

# 3. Erster Login unter http://authentik.homeserver/if/flow/initial-setup/
#    → Admin-Account mit bootstrap_email / bootstrap_password

# 4. OIDC-Clients in Authentik anlegen (Admin-UI), dann Services konfigurieren:
#    Grafana:        argocd/apps/monitoring/values.yaml → auth.generic_oauth
#    ArgoCD:         argocd/apps/argocd/argocd-cm.yaml  → oidc.config
#    Headlamp:       argocd/apps/headlamp/values.yaml   → config.oidc
#    Argo Workflows: argocd/apps/argo-workflows/values.yaml → server.sso
#    MinIO:          MinIO-Konsole → Identity → OpenID
#    Gotify/Semaphore: Traefik Forward-Auth-Middleware (Template in docs)
```

Vollständige Service-by-Service-Anleitung: **[docs/14-sso-authentik.md](docs/14-sso-authentik.md)**

---

## Service-URLs

| Service | URL | Authentifizierung |
|---|---|---|
| **Authentik** | **http://authentik.homeserver** | **SSO-Portal (nach Setup)** |
| ArgoCD | http://192.168.178.94:30080 | admin / OIDC via Authentik |
| Grafana | http://grafana.homeserver | OIDC via Authentik |
| Headlamp | http://headlamp.homeserver | OIDC via Authentik |
| Semaphore | http://semaphore.homeserver | Forward Auth via Authentik |
| Gotify | http://gotify.homeserver | Forward Auth via Authentik |
| Argo Workflows | http://argo-workflows.homeserver | OIDC via Authentik |
| MinIO | http://minio.homeserver | OIDC via Authentik |
| Paperless-NGX | http://worker-0:8000 | admin / aus Vault |
| TinyTeller | http://worker-0:3002 | — |
| Day Pilot | http://worker-0:3003 | — |

---

## Updates & Wartung

### ArgoCD-Apps updaten

```bash
# Neue App hinzufügen
mkdir -p argocd/apps/my-app
# Chart.yaml + values.yaml anlegen
git add argocd/apps/my-app && git commit -m "feat(apps): add my-app" && git push
# ArgoCD picked es innerhalb ~3 Minuten auf
```

### Ansible-Vault-Secret rotieren

```bash
# Neuen Wert verschlüsseln
ansible-vault encrypt_string 'NEUER_WERT' --name 'variable_name'

# In group_vars/all.yml ersetzen
make vault-edit

# homeserver neu provisionieren
make install
# oder nur die betroffene Rolle:
make tailscale
```

### k3s-Version pinnen

In `ansible/group_vars/all.yml`:

```yaml
k3s_version: "v1.30.2+k3s1"  # leer = immer latest stable
```

---

## Troubleshooting

### Ansible erreicht Server nicht

```bash
make ping
# Falls timeout: SSH-Key prüfen, Firewall, VPN
ssh -v ubuntu@192.168.178.95
```

### ArgoCD-App out-of-sync

```bash
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n argocd get applications'

# Manuell sync auslösen
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n argocd patch application my-app \
   -p "{\"operation\":{\"sync\":{}}}" --type merge'
```

### Docker-Compose-Dienst neu starten (worker-0)

```bash
ssh ubuntu@192.168.178.95
cd /opt/tinyteller   # oder /opt/day-pilot
sudo docker compose restart
sudo docker compose logs -f
```

### Semaphore-Bootstrap schlägt fehl (HTTP 400)

Das Bootstrap-Playbook ist idempotent — einfach nochmal ausführen:

```bash
make semaphore-bootstrap
```

### Grafana `no such column: is_service_account`

```bash
# PVC-Pfad finden
ssh ubuntu@192.168.178.94 \
  'sudo ls /var/lib/rancher/k3s/storage/ | grep grafana'

# Datenbank löschen und Deployment neu starten
ssh ubuntu@192.168.178.94 \
  'sudo rm /var/lib/rancher/k3s/storage/<pvc-name>/grafana.db'
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n monitoring rollout restart deployment/monitoring-grafana'
```

---

## Verzeichnisstruktur

```
Home-Lab/
├── ansible/
│   ├── site.yml                    ← Haupt-Playbook (homeserver)
│   ├── homeserver2.yml             ← Playbook für worker-0 (k3s-Agent + Docker Compose)
│   ├── inventory/hosts.yml         ← IP-Adressen beider Server
│   ├── group_vars/all.yml          ← Alle Konfigurationswerte + Vault-Secrets
│   ├── host_vars/
│   │   └── homeserver2/
│   │       ├── vars.yml            ← Service-Konfiguration für worker-0
│   │       └── vault.yml           ← Verschlüsselte Secrets (nicht im Git!)
│   └── roles/
│       ├── common/                 ← Basis-OS-Härtung
│       ├── k3s/                    ← Kubernetes Control-Plane
│       ├── k3s_agent/              ← Kubernetes Worker-Node
│       ├── argocd/                 ← GitOps
│       ├── dnsmasq/                ← Split-DNS
│       ├── tailscale/              ← VPN
│       ├── semaphore_secrets/      ← Semaphore-Bootstrap-Secrets
│       ├── semaphore_targets/      ← SSH-Pubkey auf Managed-Hosts pushen
│       ├── semaphore_bootstrap/    ← Semaphore REST-API-Provisionierung
│       ├── tinyteller/             ← TinyTeller (Docker Compose)
│       └── day_pilot/              ← Day Pilot (Docker Compose)
└── argocd/
    ├── bootstrap/root-applicationset.yaml
    └── apps/
        ├── monitoring/             ← VictoriaMetrics + Grafana
        ├── gotify/                 ← Push-Notifications (Android)
        ├── gotify-bridge/          ← Alertmanager → Gotify Bridge
        ├── ntfy/                   ← Push-Notifications (iOS + Android)
        ├── ntfy-bridge/            ← Alertmanager → ntfy Bridge
        ├── headlamp/               ← Kubernetes-Dashboard
        ├── sealed-secrets/         ← SealedSecrets-Controller
        ├── authentik/              ← SSO Identity Provider
        └── ...
```
