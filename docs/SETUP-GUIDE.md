# Home-Lab pke-lab.de – Multi-Node k3s Cluster
## Vollständige Installations- & Betriebsanleitung

---

## Inhaltsverzeichnis

1. [Architektur-Überblick](#1-architektur-überblick)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Schritt 1 – Ubuntu Server auf beiden Nodes installieren](#3-schritt-1--ubuntu-server-auf-beiden-nodes)
4. [Schritt 2 – Repository vorbereiten](#4-schritt-2--repository-vorbereiten)
5. [Schritt 3 – Secrets verschlüsseln](#5-schritt-3--secrets-verschlüsseln)
6. [Schritt 4 – DNS bei Netcup einrichten](#6-schritt-4--dns-bei-netcup-einrichten)
7. [Schritt 5 – Router-Portweiterleitung](#7-schritt-5--router-portweiterleitung)
8. [Schritt 6 – Ansible-Playbook ausführen](#8-schritt-6--ansible-playbook-ausführen)
9. [Schritt 7 – ArgoCD & Apps verifizieren](#9-schritt-7--argocd--apps-verifizieren)
10. [Schritt 8 – GitLab initialisieren](#10-schritt-8--gitlab-initialisieren)
11. [Schritt 9 – Zammad einrichten](#11-schritt-9--zammad-einrichten)
12. [Betrieb & Wartung](#12-betrieb--wartung)
13. [Troubleshooting](#13-troubleshooting)
14. [Neue App hinzufügen (GitOps-Weg)](#14-neue-app-hinzufügen-gitops-weg)

---

## 1. Architektur-Überblick

```
Internet
  │
  │  DNS: *.pke-lab.de → öffentliche IP
  │  Router: Port 80/443 → 192.168.178.200
  ▼
┌─────────────────────────────────────────────────┐
│  Heimnetz 192.168.178.0/24                      │
│                                                 │
│  MetalLB VIP: 192.168.178.200 (Traefik)         │
│                                                 │
│  ┌─────────────────┐   ┌─────────────────────┐  │
│  │   Node 94       │   │   Node 95           │  │
│  │ 192.168.178.94  │   │ 192.168.178.95      │  │
│  │                 │   │                     │  │
│  │ k3s Server      │   │ k3s Agent           │  │
│  │ (Control Plane  │   │ (Worker Only)       │  │
│  │  + Worker)      │   │                     │  │
│  │                 │   │ HDD /mnt/hdd        │  │
│  │ Traefik         │   │ GitLab-Daten        │  │
│  │ ArgoCD          │   │ GitLab-Pods         │  │
│  │ cert-manager    │   │ (nodeSelector)      │  │
│  │ Zammad          │   │                     │  │
│  └─────────────────┘   └─────────────────────┘  │
│                                                 │
│  Tailscale-Mesh (WireGuard) auf beiden Nodes    │
└─────────────────────────────────────────────────┘

Traffic-Flow (extern):
Browser → DNS(*.pke-lab.de) → Router-NAT →
  192.168.178.200:443 → Traefik → Pod

Traffic-Flow (VPN):
Tailscale-Client → WireGuard → Node 94/95 → Pod
```

### Komponenten-Übersicht

| Komponente    | Namespace       | Node     | Zweck                              |
|---------------|-----------------|----------|------------------------------------|
| k3s           | –               | 94+95    | Kubernetes-Cluster                 |
| MetalLB       | metallb-system  | 94       | LoadBalancer-IPs                   |
| Traefik       | traefik         | 94+95    | Ingress-Controller (2 Replicas)    |
| cert-manager  | cert-manager    | 94       | TLS-Zertifikate (Let's Encrypt)    |
| ArgoCD        | argocd          | 94       | GitOps-Controller                  |
| Tailscale     | –               | 94+95    | VPN (Bare Metal)                   |
| Zammad        | zammad          | 94/95    | Helpdesk                           |
| GitLab CE     | gitlab          | **95**   | Git + CI/CD (HDD-Storage)          |

---

## 2. Voraussetzungen

### Auf deiner Workstation (Laptop/Desktop)
```bash
# Ansible >= 2.14
pip install ansible ansible-lint

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm (optional, Ansible macht das remote)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# SSH-Key generieren (falls noch nicht vorhanden)
ssh-keygen -t ed25519 -C "homelab"
```

### SSH-Zugriff auf beide Nodes vorbereiten
```bash
ssh-copy-id ubuntu@192.168.178.94
ssh-copy-id ubuntu@192.168.178.95
# Verbindung testen:
ssh ubuntu@192.168.178.94 "hostname && id"
ssh ubuntu@192.168.178.95 "hostname && id"
```

### Tailscale Auth-Key
1. https://login.tailscale.com/admin/settings/keys
2. „Generate auth key" → Reusable, Expiry: 90 Tage
3. Key notieren: `tskey-auth-XXXXXXXXXXXXXXXX`

---

## 3. Schritt 1 – Ubuntu Server auf beiden Nodes

Beide Nodes benötigen **Ubuntu Server 24.04 LTS** (minimal install).

### Während der Installation
- Benutzername: `ubuntu`
- SSH-Server: ✅ installieren
- Partitionierung Node 95:
  - `/dev/sda` → Systempartition
  - `/dev/sdb` → HDD komplett für GitLab (wird von Ansible formatiert)
- Swap: **nicht einrichten** (Ansible deaktiviert es)

### Nach der Installation – manuell auf beiden Nodes
```bash
# sudo ohne Passwort
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ubuntu

# Statische IPs setzen (netplan)
# Node 94:
sudo nano /etc/netplan/00-installer-config.yaml
```

**Node 94** `/etc/netplan/00-installer-config.yaml`:
```yaml
network:
  version: 2
  ethernets:
    ens18:           # Interface-Name anpassen (ip link show)
      addresses: [192.168.178.94/24]
      gateway4: 192.168.178.1
      nameservers:
        addresses: [192.168.178.1, 8.8.8.8]
```

**Node 95** analog mit `192.168.178.95`.

```bash
sudo netplan apply
```

---

## 4. Schritt 2 – Repository vorbereiten

```bash
# Entweder das Original forken oder direkt klonen
git clone https://github.com/jaydee94/home-server.git
cd home-server

# Oder: Diesen Stand als neues privates Repo anlegen
git remote set-url origin https://github.com/DEIN_USER/home-server.git
```

### Dateien anpassen

```bash
# 1) Inventory prüfen – IPs sollten bereits korrekt sein
cat ansible/inventory/hosts.yml

# 2) group_vars anpassen (IPs + Domain sind bereits korrekt)
# Wichtig: HDD-Device auf Node 95 korrekt setzen!
# Prüfen welches Device die HDD hat:
ssh ubuntu@192.168.178.95 "lsblk"
# Dann in group_vars/all.yml:  hdd_device: /dev/sdb1  (oder /dev/sdb)
nano ansible/group_vars/all.yml

# 3) ArgoCD Repo-URL anpassen
# In ansible/group_vars/all.yml:
#   argocd_repo_url: https://github.com/DEIN_USER/home-server.git
```

---

## 5. Schritt 3 – Secrets verschlüsseln

```bash
# Ansible-Vault-Passwort festlegen (wird bei Playbook-Run abgefragt)
# Optional: in .vault_pass speichern (NICHT ins Git pushen!)

# k3s Cluster-Token generieren und verschlüsseln
K3S_TOKEN=$(openssl rand -hex 32)
ansible-vault encrypt_string "$K3S_TOKEN" --name 'k3s_token'
# → Den !vault-Block in ansible/group_vars/all.yml einfügen

# Tailscale Auth-Key verschlüsseln
ansible-vault encrypt_string 'tskey-auth-DEIN_KEY' --name 'tailscale_auth_key'
# → Den !vault-Block in ansible/group_vars/all.yml einfügen

# .gitignore prüfen – vault_pass nie commiten!
echo ".vault_pass" >> .gitignore
echo "*.vault_pass" >> .gitignore
```

---

## 6. Schritt 4 – DNS bei Netcup einrichten

Im Netcup-Kundenportal unter DNS-Verwaltung für `pke-lab.de`:

| Typ    | Name           | Wert               | TTL  |
|--------|----------------|--------------------|------|
| A      | @              | DEINE_ÖFFENTL_IP   | 300  |
| A      | *              | DEINE_ÖFFENTL_IP   | 300  |
| AAAA   | @              | DEINE_IPv6 (opt.)  | 300  |

> **Tipp:** Die öffentliche IP findest du mit `curl ifconfig.me` auf einem der Nodes.

> **Hinweis:** Der Wildcard-Record `*.pke-lab.de` sorgt dafür, dass alle
> Subdomains automatisch auf deine öffentliche IP zeigen. Kein weiterer
> DNS-Eintrag pro App nötig.

### DNS prüfen (nach ~5–15 Minuten)
```bash
dig argocd.pke-lab.de +short
dig gitlab.pke-lab.de +short
dig zammad.pke-lab.de +short
# Alle sollten deine öffentliche IP zurückgeben
```

---

## 7. Schritt 5 – Router-Portweiterleitung

In der FritzBox (oder anderem Router):

| Port extern | Port intern | Ziel-IP          | Protokoll |
|-------------|-------------|------------------|-----------|
| 80          | 80          | 192.168.178.200  | TCP       |
| 443         | 443         | 192.168.178.200  | TCP       |

> Die IP `192.168.178.200` ist noch nicht aktiv – das ist der MetalLB VIP,
> der nach dem Ansible-Run verfügbar ist. Die Portweiterleitung kann trotzdem
> vorab eingerichtet werden.

**FritzBox-Pfad:**
Heimnetz → Netzwerk → NAT / Portfreigaben → Neue Portfreigabe

---

## 8. Schritt 6 – Ansible-Playbook ausführen

```bash
# Collections installieren
ansible-galaxy collection install -r ansible/requirements.yml

# Connectivity-Test
ansible -i ansible/inventory/hosts.yml k3s_cluster -m ping

# Dry-Run (Check-Mode)
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --ask-vault-pass --check

# Live-Run (dauert ~10–15 Minuten)
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --ask-vault-pass

# Optional: Verbose-Output
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --ask-vault-pass -v
```

### Was das Playbook macht (in dieser Reihenfolge)

1. **Common** – Ubuntu-Hardening, UFW, sysctl auf beiden Nodes
2. **Storage** – HDD auf Node 95 formatieren + mounten
3. **Tailscale** – VPN auf beiden Nodes, Node 94 als Subnet-Router
4. **k3s Server** – Control Plane + Worker auf Node 94 (Traefik + servicelb disabled)
5. **k3s Agent** – Node 95 joint dem Cluster, Label `storage=hdd`
6. **MetalLB** – Helm-Install + IPAddressPool + L2Advertisement
7. **cert-manager** – Helm-Install + ClusterIssuer (Prod + Staging)
8. **ArgoCD** – Helm-Install + Root-ApplicationSet bootstrapt alle Apps

### Erwarteter Output am Ende
```
╔══════════════════════════════════════════════════════╗
║           Home-Lab pke-lab.de ist bereit!           ║
╠══════════════════════════════════════════════════════╣
║  ArgoCD UI:    https://argocd.pke-lab.de            ║
║  Username:     admin                                 ║
║  Password:     <auto-generiert>                     ║
╠══════════════════════════════════════════════════════╣
║  MetalLB VIP:  192.168.178.200                      ║
║  Traefik:      https://traefik.pke-lab.de           ║
╚══════════════════════════════════════════════════════╝
```

---

## 9. Schritt 7 – ArgoCD & Apps verifizieren

```bash
# kubeconfig auf Workstation holen
scp ubuntu@192.168.178.94:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab
# IP im kubeconfig anpassen
sed -i 's/127.0.0.1/192.168.178.94/' ~/.kube/config-homelab
export KUBECONFIG=~/.kube/config-homelab

# Cluster-Status
kubectl get nodes -o wide
# Erwartete Ausgabe:
# NAME      STATUS   ROLES                  AGE   VERSION   INTERNAL-IP
# node-94   Ready    control-plane,master   5m    v1.29.x   192.168.178.94
# node-95   Ready    worker                 4m    v1.29.x   192.168.178.95

# MetalLB prüfen
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool

# Traefik LoadBalancer-IP prüfen
kubectl -n traefik get svc
# EXTERNAL-IP sollte 192.168.178.200 zeigen

# ArgoCD Apps prüfen
kubectl -n argocd get applications
# Alle Apps sollten nach ~3 Minuten auf Synced/Healthy wechseln

# cert-manager prüfen
kubectl get clusterissuer
# letsencrypt-prod und letsencrypt-staging sollten READY=True zeigen

# TLS-Zertifikat für ArgoCD prüfen
kubectl -n argocd get certificate
kubectl -n argocd describe certificate argocd-tls
```

### ArgoCD Web-UI öffnen
```
https://argocd.pke-lab.de
Benutzer: admin
Passwort: kubectl -n argocd get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## 10. Schritt 8 – GitLab initialisieren

GitLab braucht beim ersten Start ~5–10 Minuten.

```bash
# Pod-Status überwachen
kubectl -n gitlab get pods -w

# Alle Pods sollten Running/Ready sein:
# gitlab-webservice-xxx    2/2   Running
# gitlab-sidekiq-xxx       1/1   Running
# gitlab-gitaly-xxx        1/1   Running
# gitlab-postgresql-xxx    1/1   Running
# gitlab-redis-xxx         1/1   Running

# Initial root-Passwort holen
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### GitLab Web-UI
```
https://gitlab.pke-lab.de
Benutzer: root
Passwort: (aus dem obigen Befehl)
```

### Daten auf HDD verifizieren (auf Node 95)
```bash
ssh ubuntu@192.168.178.95 "df -h /mnt/hdd && ls -la /mnt/hdd/gitlab/"
```

---

## 11. Schritt 9 – Zammad einrichten

```bash
# Zammad-Status
kubectl -n zammad get pods -w
# Elasticsearch braucht länger – warten bis alle Pods Ready

# URL öffnen
# https://zammad.pke-lab.de
# → Setup-Wizard startet automatisch
```

### Zammad Setup-Wizard
1. **Sprache** wählen: Deutsch
2. **Admin-Account** anlegen (E-Mail + Passwort)
3. **E-Mail-Konto** konfigurieren (optional)
4. **System-URL** bestätigen: `https://zammad.pke-lab.de`

---

## 12. Betrieb & Wartung

### Cluster aktualisieren
```bash
# Ansible-Run aktualisiert alle Komponenten idempotent
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --ask-vault-pass

# Nur bestimmte Roles ausführen (Tags)
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --ask-vault-pass --tags k3s_server,k3s_agent
```

### ArgoCD-Apps synchronisieren
```bash
# Alle Apps forciert synchen
argocd app sync --all

# Einzelne App
argocd app sync gitlab
argocd app sync zammad
```

### Node 95 (Storage-Node) prüfen
```bash
# HDD-Belegung
ssh ubuntu@192.168.178.95 "df -h /mnt/hdd"

# GitLab-Daten
ssh ubuntu@192.168.178.95 "du -sh /mnt/hdd/gitlab/*"
```

### Zertifikate überwachen
```bash
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
# READY=True = Zertifikat aktiv und gültig
```

### Backup GitLab
```bash
# GitLab Backup über kubectl exec
kubectl -n gitlab exec deploy/gitlab-webservice -- \
  gitlab-backup create BACKUP=manual

# Backup liegt dann auf dem PV (HDD auf Node 95)
ssh ubuntu@192.168.178.95 "ls -la /mnt/hdd/gitlab/data/backups/"
```

### k3s-Node drainieren (für Wartung)
```bash
# Node 95 für Wartung drainieren
kubectl drain node-95 --ignore-daemonsets --delete-emptydir-data

# Wartung durchführen...

# Node wieder in Betrieb nehmen
kubectl uncordon node-95
```

---

## 13. Troubleshooting

### MetalLB gibt keine IP
```bash
kubectl -n metallb-system describe ipaddresspool homelab-pool
kubectl -n metallb-system logs deploy/metallb-controller
# Häufige Ursache: Webhook noch nicht bereit → etwas warten
```

### Let's Encrypt Zertifikat schlägt fehl
```bash
kubectl describe certificate -n <namespace> <cert-name>
kubectl describe certificaterequest -n <namespace>
kubectl -n cert-manager logs deploy/cert-manager

# HTTP-01 Challenge prüfen:
# 1. Ist Port 80 vom Internet erreichbar?
curl http://pke-lab.de/.well-known/acme-challenge/test
# 2. DNS korrekt?
dig pke-lab.de +short   # Muss öffentliche IP sein

# Staging testen (kein Rate-Limit):
# ClusterIssuer auf letsencrypt-staging wechseln,
# Certificate löschen und neu erstellen lassen
```

### GitLab-Pod startet nicht
```bash
kubectl -n gitlab describe pod <pod-name>
kubectl -n gitlab logs <pod-name> --previous

# HDD gemountet?
ssh ubuntu@192.168.178.95 "mount | grep hdd"

# PV gebunden?
kubectl get pv | grep gitlab
kubectl get pvc -n gitlab
```

### k3s-Node nicht verbunden
```bash
# Auf Node 95:
sudo systemctl status k3s-agent
sudo journalctl -u k3s-agent -f

# Token prüfen (muss auf beiden Nodes identisch sein)
sudo cat /var/lib/rancher/k3s/server/node-token  # Node 94
```

### Traefik leitet nicht weiter
```bash
kubectl -n traefik get svc traefik
# EXTERNAL-IP = 192.168.178.200? Falls nicht:
kubectl -n metallb-system get pods
# MetalLB-Speaker auf beiden Nodes laufen?
kubectl -n metallb-system get pods -o wide
```

---

## 14. Neue App hinzufügen (GitOps-Weg)

Der Root-ApplicationSet erkennt automatisch jeden neuen Ordner unter `argocd/apps/`.

```bash
# 1) App-Ordner anlegen
mkdir -p argocd/apps/my-new-app

# 2) Helm-Chart referenzieren (Chart.yaml + values.yaml)
cat > argocd/apps/my-new-app/Chart.yaml << 'EOF'
apiVersion: v2
name: my-new-app
version: 0.1.0
dependencies:
  - name: my-chart
    version: ">=1.0.0"
    repository: https://charts.example.com
EOF

# 3) Ingress mit TLS in values.yaml
cat > argocd/apps/my-new-app/values.yaml << 'EOF'
my-chart:
  ingress:
    enabled: true
    className: traefik
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    hosts:
      - host: my-new-app.pke-lab.de
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: my-new-app-tls
        hosts:
          - my-new-app.pke-lab.de
EOF

# 4) Committen und pushen
git add argocd/apps/my-new-app
git commit -m "feat(apps): add my-new-app"
git push

# 5) Nach ~3 Minuten erscheint die App in ArgoCD
kubectl -n argocd get application my-new-app
```

> **Kein DNS-Eintrag nötig** – der Wildcard-Record `*.pke-lab.de` ist
> bereits aktiv. cert-manager stellt automatisch ein TLS-Zertifikat aus.

---

## Repository-Struktur (Ziel)

```
home-server/
├── ansible/
│   ├── site.yml                     ← Entry-Point
│   ├── requirements.yml
│   ├── inventory/
│   │   └── hosts.yml                ← Node 94 + 95
│   ├── group_vars/
│   │   └── all.yml                  ← Alle Variablen + Vault-Secrets
│   └── roles/
│       ├── common/                  ← OS-Hardening, UFW
│       ├── storage/                 ← HDD-Mount Node 95
│       ├── tailscale/               ← VPN
│       ├── k3s_server/              ← Control Plane
│       ├── k3s_agent/               ← Worker
│       ├── metallb/                 ← LoadBalancer
│       ├── cert_manager/            ← TLS
│       └── argocd/                  ← GitOps
└── argocd/
    ├── bootstrap/
    │   └── root-applicationset.yaml ← Bootstrapt alle Apps
    └── apps/
        ├── traefik/                 ← Ingress (MetalLB VIP)
        ├── cert-manager/           ← (optional, alternativ Ansible)
        ├── zammad/                  ← Helpdesk (zammad.pke-lab.de)
        ├── gitlab/                  ← Git + CI/CD (gitlab.pke-lab.de)
        │   ├── Chart.yaml
        │   ├── values.yaml
        │   └── pv-gitlab-data.yaml  ← PV auf Node 95 HDD
        ├── monitoring/              ← VictoriaMetrics + Grafana
        ├── argocd/                  ← ArgoCD selbst (self-managed)
        └── ...                      ← Weitere Apps
```
