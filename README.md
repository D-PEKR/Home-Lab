# HomeLab

Automatisiertes, GitOps-getriebenes Home-Lab auf zwei physischen Nodes.
Ein einziger Ansible-Run provisioniert beide Nodes, richtet einen k3s-Cluster ein
und bootstrapped ArgoCD, das von dort an alle Anwendungen aus diesem Repository
selbststaendig deployed und aktuell haelt.

---

## Architektur

```
Internet
    |
    |  DNS: *.pke-lab.de  ->  oeffentliche IP
    |  Router: Port 80/443  ->  192.168.178.200
    v
+--------------------------------------------------+
|  Heimnetz 192.168.178.0/24                       |
|                                                  |
|  MetalLB VIP: 192.168.178.200  (Traefik)         |
|                                                  |
|  +---------------------+  +--------------------+ |
|  |  Node 94            |  |  Node 95           | |
|  |  192.168.178.94     |  |  192.168.178.95    | |
|  |                     |  |                    | |
|  |  k3s Control Plane  |  |  k3s Worker        | |
|  |  + Worker           |  |                    | |
|  |                     |  |  HDD /mnt/hdd      | |
|  |  Traefik            |  |  GitLab-Daten      | |
|  |  ArgoCD             |  |  GitLab-Pods       | |
|  |  cert-manager       |  |  (nodeSelector)    | |
|  |  MetalLB            |  |                    | |
|  |  Zammad             |  |                    | |
|  +---------------------+  +--------------------+ |
+--------------------------------------------------+
```

### Komponenten

| Komponente   | Namespace        | Zweck                                        |
|--------------|------------------|----------------------------------------------|
| k3s          | -                | Kubernetes-Cluster (Control Plane + Worker)  |
| MetalLB      | metallb-system   | LoadBalancer-IPs im LAN per L2               |
| Traefik      | traefik          | Ingress-Controller, 2 Replicas               |
| cert-manager | cert-manager     | Automatische TLS-Zertifikate via Let's Encrypt|
| ArgoCD       | argocd           | GitOps-Controller                            |
| GitLab CE    | gitlab           | Git-Server, CI/CD (Storage auf Node 95 HDD)  |
| Zammad       | zammad           | Helpdesk                                     |

### Erreichbare Dienste nach dem Deployment

| URL                          | Dienst            |
|------------------------------|-------------------|
| https://argocd.pke-lab.de    | ArgoCD            |
| https://gitlab.pke-lab.de    | GitLab CE         |
| https://zammad.pke-lab.de    | Zammad Helpdesk   |
| https://traefik.pke-lab.de   | Traefik Dashboard |

---

## Repository-Struktur

```
HomeLab/
+-- ansible/
|   +-- site.yml                        Playbook-Einstiegspunkt
|   +-- requirements.yml                Ansible Galaxy Collections
|   +-- inventory/
|   |   +-- hosts.yml                   Node 94 (server) + Node 95 (agent)
|   +-- group_vars/
|   |   +-- all.yml                     Alle Variablen, Vault-Secrets
|   +-- roles/
|       +-- common/                     OS-Hardening, UFW, sysctl
|       +-- storage/                    HDD formatieren und mounten (Node 95)
|       +-- k3s_server/                 k3s Control Plane auf Node 94
|       +-- k3s_agent/                  k3s Worker auf Node 95
|       +-- metallb/                    LoadBalancer IP-Pool
|       +-- cert_manager/               TLS-Zertifikate
|       +-- argocd/                     GitOps-Controller
+-- argocd/
|   +-- bootstrap/
|   |   +-- root-applicationset.yaml    Bootstrapt alle Apps aus argocd/apps/
|   +-- apps/
|       +-- traefik/                    Ingress mit MetalLB LoadBalancer-IP
|       +-- gitlab/                     GitLab CE mit HDD-Storage auf Node 95
|       +-- zammad/                     Helpdesk
+-- Makefile                            Convenience-Targets
+-- README.md                           Diese Datei
```

---

## Voraussetzungen

### Hardware

- Node 94: beliebiger x86-Rechner, min. 4 GB RAM, min. 20 GB Disk
  IP-Adresse: 192.168.178.94
- Node 95: beliebiger x86-Rechner, min. 8 GB RAM (GitLab), Systemdisk + separate HDD
  IP-Adresse: 192.168.178.95
  Die separate HDD nimmt alle GitLab-Daten auf und wird von Ansible formatiert.

### Workstation (Laptop oder Desktop, von dem Ansible ausgefuehrt wird)

```
Python >= 3.9
Ansible >= 2.14
kubectl
```

Installation:

```
pip install ansible ansible-lint
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
```

### SSH-Key

```
ssh-keygen -t ed25519 -C "homelab"
ssh-copy-id ubuntu@192.168.178.94
ssh-copy-id ubuntu@192.168.178.95
```

Verbindung testen:

```
ssh ubuntu@192.168.178.94 "hostname"
ssh ubuntu@192.168.178.95 "hostname"
```

---

## Deployment

### Schritt 1 - Ubuntu Server auf beiden Nodes installieren

Ubuntu Server 24.04 LTS (minimale Installation) auf beiden Rechnern installieren.

Waehrend der Installation:
- Benutzername: ubuntu
- SSH-Server installieren: ja
- Swap: nicht einrichten (wird von Ansible deaktiviert)
- Node 95: Systemdisk auf dem ersten Laufwerk, HDD frei lassen

Nach der Installation sudo ohne Passwort einrichten (auf beiden Nodes):

```
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ubuntu
```

Statische IP setzen (auf beiden Nodes). Beispiel fuer Node 94:

```
sudo nano /etc/netplan/00-installer-config.yaml
```

```yaml
network:
  version: 2
  ethernets:
    ens18:
      addresses: [192.168.178.94/24]
      routes:
        - to: default
          via: 192.168.178.1
      nameservers:
        addresses: [192.168.178.1, 8.8.8.8]
```

Fuer Node 95 analog mit 192.168.178.95. Interface-Name mit `ip link show` pruefen.

```
sudo netplan apply
```


### Schritt 2 - Repository klonen

```
git clone https://github.com/D-PEKR/HomeLab.git
cd HomeLab
```


### Schritt 3 - Konfiguration anpassen

**HDD-Device auf Node 95 ermitteln:**

```
ssh ubuntu@192.168.178.95 "lsblk"
```

Die Ausgabe zeigt alle Laufwerke. Die Systemdisk ist typischerweise /dev/sda.
Die separate HDD ist /dev/sdb oder /dev/sdc. Den Devicenamen notieren.

**ansible/group_vars/all.yml anpassen:**

Die folgenden Werte sind bereits auf das pke-lab.de-Setup voreingestellt.
Bei abweichender Hardware oder Domain entsprechend aendern:

```yaml
# Netzwerk
node_server_ip: 192.168.178.94
node_agent_ip:  192.168.178.95
ingress_vip:    192.168.178.200    # MetalLB-IP fuer Traefik

# Domain
base_domain:        pke-lab.de
letsencrypt_email:  admin@pke-lab.de

# HDD auf Node 95 (Device aus lsblk-Ausgabe eintragen)
hdd_device:     /dev/sdb           # anpassen!
hdd_mount_path: /mnt/hdd
hdd_filesystem: ext4

# ArgoCD - auf eigenes Repository zeigen lassen
argocd_repo_url: https://github.com/D-PEKR/HomeLab.git
```

**ansible/inventory/hosts.yml pruefen:**

```yaml
k3s_server:
  hosts:
    node-94:
      ansible_host: 192.168.178.94

k3s_agent:
  hosts:
    node-95:
      ansible_host: 192.168.178.95
      hdd_device: /dev/sdb          # gleicher Wert wie in all.yml
```


### Schritt 4 - Secrets verschluesseln

Der k3s-Cluster-Token verbindet Node 94 und Node 95. Er muss mit Ansible Vault
verschluesselt in group_vars/all.yml gespeichert werden.

Token generieren und verschluesseln:

```
make vault-k3s-token
```

Oder manuell:

```
ansible-vault encrypt_string "$(openssl rand -hex 32)" --name 'k3s_token'
```

Das Vault-Passwort wird bei diesem Befehl abgefragt und festgelegt.
Es wird spaeter bei jedem Playbook-Run als --ask-vault-pass benoetigt.

Die Ausgabe sieht so aus:

```
k3s_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  61383534623130623338643831623538...
  ...
```

Diesen Block komplett (einschliesslich der Zeile k3s_token: !vault |) in
ansible/group_vars/all.yml an der Stelle des bestehenden k3s_token-Platzhalters
einfuegen. Den Kommentar innerhalb des verschluesselten Blocks entfernen,
da er den Vault-Block ungueltig macht.

Korrekt:

```yaml
k3s_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  61383534623130623338643831623538...
  3666363535653238363438653132633835...

# naechste Variable
argocd_namespace: argocd
```

Falsch (Kommentar im Vault-Block):

```yaml
k3s_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  61383534623130623338643831623538...
  # dieser Kommentar hier macht den Block ungueltig
```

Vault-Block validieren:

```
ansible -i ansible/inventory/hosts.yml node-94 \
  -m debug -a "var=k3s_token" \
  --ask-vault-pass \
  --playbook-dir ansible/
```

Bei korrekter Konfiguration gibt der Befehl den entschluesselten Token-String zurueck.


### Schritt 5 - DNS bei Netcup einrichten

Im Netcup-Kundenportal unter DNS-Verwaltung fuer pke-lab.de folgende Records anlegen:

| Typ | Name | Wert                  | TTL |
|-----|------|-----------------------|-----|
| A   | @    | OEFFENTLICHE_IP       | 300 |
| A   | *    | OEFFENTLICHE_IP       | 300 |

Die oeffentliche IP ermitteln:

```
ssh ubuntu@192.168.178.94 "curl -s ifconfig.me"
```

Der Wildcard-Record *.pke-lab.de sorgt dafuer, dass jede Subdomain automatisch
aufgeloest wird. Fuer neue Anwendungen ist kein weiterer DNS-Eintrag noetig.

DNS nach ca. 5-15 Minuten pruefen:

```
dig argocd.pke-lab.de +short
dig gitlab.pke-lab.de +short
```

Beide Befehle sollten die oeffentliche IP ausgeben.


### Schritt 6 - Portweiterleitung im Router einrichten

In der FritzBox unter Heimnetz > Netzwerk > NAT / Portfreigaben:

| Externer Port | Interner Port | Ziel-IP          | Protokoll |
|---------------|---------------|------------------|-----------|
| 80            | 80            | 192.168.178.200  | TCP       |
| 443           | 443           | 192.168.178.200  | TCP       |

Die Ziel-IP 192.168.178.200 ist der MetalLB-VIP, den Traefik nach dem
Ansible-Run bekommt. Die Weiterleitung kann vorab eingerichtet werden.


### Schritt 7 - Ansible Galaxy Collections installieren

```
make deps
```

Oder manuell:

```
ansible-galaxy collection install -r ansible/requirements.yml
```


### Schritt 8 - Optionaler Dry-Run

Der Check-Mode simuliert alle Tasks ohne echte Aenderungen. Netzwerk- und
Cluster-abhaengige Tasks werden dabei uebersprungen, zeigt aber
Konfigurationsfehler fruehzeitig auf.

```
make check
```

Oder nur fuer Common und Storage (zuverlaessiger im Check-Mode):

```
make check-base
```


### Schritt 9 - Playbook ausfuehren

```
make install
```

Oder manuell:

```
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml --ask-vault-pass
```

Das Playbook fuehrt folgende Schritte der Reihe nach aus:

1. Common - Ubuntu-Hardening, UFW-Firewall, sysctl, br_netfilter auf beiden Nodes
2. Storage - HDD auf Node 95 formatieren (nur wenn leer) und mounten
3. k3s Server - k3s Control Plane + Worker auf Node 94, Helm-Installation
4. k3s Agent - Node 95 joint den Cluster, Label storage=hdd wird gesetzt
5. MetalLB - Helm-Deployment, IPAddressPool 192.168.178.200-210, L2Advertisement
6. cert-manager - Helm-Deployment, ClusterIssuer fuer Let's Encrypt (Prod + Staging)
7. ArgoCD - Helm-Deployment, Root-ApplicationSet bootstrapt alle Apps aus argocd/apps/

Laufzeit: ca. 10-15 Minuten bei erstmaligem Run.

Am Ende gibt das Playbook folgende Ausgabe:

```
ArgoCD URL: https://argocd.pke-lab.de
Username:   admin
Password:   <generiertes Passwort>
```


### Schritt 10 - Deployment verifizieren

**kubeconfig auf die Workstation holen:**

```
scp ubuntu@192.168.178.94:/etc/rancher/k3s/k3s.yaml ~/.kube/config-homelab
sed -i 's/127.0.0.1/192.168.178.94/' ~/.kube/config-homelab
export KUBECONFIG=~/.kube/config-homelab
```

**Cluster-Status pruefen:**

```
kubectl get nodes -o wide
```

Erwartete Ausgabe:

```
NAME      STATUS   ROLES                  AGE   INTERNAL-IP
node-94   Ready    control-plane,master   5m    192.168.178.94
node-95   Ready    worker                 4m    192.168.178.95
```

**MetalLB pruefen:**

```
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool
```

**Traefik LoadBalancer-IP pruefen:**

```
kubectl -n traefik get svc
```

Die EXTERNAL-IP muss 192.168.178.200 zeigen.

**ArgoCD Apps pruefen:**

```
kubectl -n argocd get applications
```

Nach ca. 3 Minuten sollten alle Apps den Status Synced/Healthy zeigen.

**TLS-Zertifikate pruefen:**

```
kubectl get clusterissuer
kubectl get certificates --all-namespaces
```

Alle ClusterIssuer und Certificates muessen READY=True zeigen.


### Schritt 11 - ArgoCD Web-UI

```
https://argocd.pke-lab.de
Benutzer: admin
Passwort: make argocd-password
```

Von dort aus sind alle deployten Anwendungen sichtbar und verwaltbar.


### Schritt 12 - GitLab initialisieren

GitLab benoetigt beim ersten Start ca. 5-10 Minuten zum Hochfahren.

```
kubectl -n gitlab get pods -w
```

Alle Pods muessen Running/Ready sein, bevor die UI erreichbar ist.

Initial-Passwort fuer den root-Benutzer:

```
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Anmeldung unter https://gitlab.pke-lab.de mit Benutzer root und dem ausgegebenen Passwort.

GitLab-Daten auf Node 95 pruefen:

```
ssh ubuntu@192.168.178.95 "df -h /mnt/hdd && ls -la /mnt/hdd/gitlab/"
```


### Schritt 13 - Zammad einrichten

```
kubectl -n zammad get pods -w
```

Elasticsearch benoetigt etwas laenger zum Starten. Sobald alle Pods Ready sind,
ist die UI unter https://zammad.pke-lab.de erreichbar.

Beim ersten Aufruf startet automatisch der Setup-Wizard:
1. Sprache waehlen
2. Admin-Konto anlegen
3. System-URL bestaetigen: https://zammad.pke-lab.de

---

## Neue Anwendung hinzufuegen

Der Root-ApplicationSet erkennt automatisch jeden neuen Ordner unter argocd/apps/.
Konvention: Ordnername = App-Name = Kubernetes-Namespace.

```
mkdir -p argocd/apps/meine-app
```

Minimales Helm-Chart anlegen:

```
# argocd/apps/meine-app/Chart.yaml
apiVersion: v2
name: meine-app
version: 0.1.0
dependencies:
  - name: chart-name
    version: ">=1.0.0"
    repository: https://charts.example.com
```

Ingress mit automatischem TLS in values.yaml:

```
# argocd/apps/meine-app/values.yaml
chart-name:
  ingress:
    enabled: true
    className: traefik
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    hosts:
      - host: meine-app.pke-lab.de
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: meine-app-tls
        hosts:
          - meine-app.pke-lab.de
```

Committen und pushen:

```
git add argocd/apps/meine-app
git commit -m "feat: add meine-app"
git push
```

ArgoCD erkennt den neuen Ordner innerhalb von ca. 3 Minuten und deployt die App.
Ein neuer DNS-Eintrag ist nicht noetig, der Wildcard-Record ist bereits aktiv.

---

## Betrieb und Wartung

### Cluster aktualisieren

```
make install
```

Der Ansible-Run ist vollstaendig idempotent. Er aktualisiert Pakete, k3s und
alle Helm-Charts wenn auto_upgrade: true in group_vars/all.yml gesetzt ist.

### Nur einzelne Rollen ausfuehren

```
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --ask-vault-pass --tags common
```

Verfuegbare Tags entsprechen den Rollennamen: common, storage, k3s_server,
k3s_agent, metallb, cert_manager, argocd.

### ArgoCD-Apps manuell synchronisieren

```
# Alle Apps
kubectl -n argocd get applications

# Einzelne App per kubectl
kubectl -n argocd patch application gitlab \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Zertifikate pruefen

```
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
```

### Node 95 fuer Wartung drainieren

```
kubectl drain node-95 --ignore-daemonsets --delete-emptydir-data
# Wartung durchfuehren
kubectl uncordon node-95
```

### GitLab-Backup erstellen

```
kubectl -n gitlab exec deploy/gitlab-webservice -- \
  gitlab-backup create BACKUP=manual
```

Das Backup liegt auf der HDD unter /mnt/hdd/gitlab/data/backups/ auf Node 95.

---

## Troubleshooting

### MetalLB vergibt keine IP

```
kubectl -n metallb-system describe ipaddresspool homelab-pool
kubectl -n metallb-system logs deploy/metallb-controller
```

Haeufige Ursache: MetalLB-Webhook noch nicht bereit. Einige Sekunden warten
und erneut pruefen.

### Let's Encrypt Zertifikat schlaegt fehl

```
kubectl describe certificate -n <namespace> <zertifikat-name>
kubectl -n cert-manager logs deploy/cert-manager
```

Checkliste:
- Ist Port 80 vom Internet aus erreichbar? Test: curl http://pke-lab.de
- Zeigt dig pke-lab.de +short die oeffentliche IP?
- Ist die Portweiterleitung im Router aktiv?

Zum Testen ohne Rate-Limit den Staging-Issuer verwenden. In group_vars/all.yml:

```yaml
letsencrypt_server: https://acme-staging-v02.api.letsencrypt.org/directory
```

### GitLab-Pod startet nicht

```
kubectl -n gitlab describe pod <pod-name>
kubectl -n gitlab logs <pod-name> --previous
```

HDD-Mount pruefen:

```
ssh ubuntu@192.168.178.95 "mount | grep hdd && ls /mnt/hdd/gitlab/"
```

PersistentVolumes pruefen:

```
kubectl get pv | grep gitlab
kubectl get pvc -n gitlab
```

Alle PVCs muessen Bound sein.

### k3s Agent verbindet sich nicht

Auf Node 95 pruefen:

```
ssh ubuntu@192.168.178.95 "sudo systemctl status k3s-agent"
ssh ubuntu@192.168.178.95 "sudo journalctl -u k3s-agent -n 50"
```

Haeufige Ursache: k3s_token stimmt nicht ueberein oder Node 94 ist noch nicht
vollstaendig hochgefahren.

### Traefik hat keine EXTERNAL-IP

```
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system logs deploy/metallb-speaker -c speaker
```

Der MetalLB Speaker muss auf beiden Nodes laufen (DaemonSet).

### Ansible-Vault Fehler "Odd-length string"

Ein Kommentar innerhalb des Vault-Blocks in group_vars/all.yml macht den
verschluesselten Wert ungueltig. Den Block pruefen:

```
grep -n '' ansible/group_vars/all.yml | sed -n '34,50p'
```

Alle eingerueckten Zeilen zwischen !vault | und der naechsten uneingerueckten
Variable muessen ausschliesslich hexadezimale Zeilen des verschluesselten Werts
enthalten. Kommentarzeilen innerhalb des Blocks entfernen.

---

## Makefile-Referenz

| Target             | Beschreibung                                      |
|--------------------|---------------------------------------------------|
| make install       | Vollstaendigen Ansible-Run ausfuehren             |
| make check         | Dry-Run ohne Aenderungen                          |
| make check-base    | Dry-Run nur fuer Common und Storage               |
| make ping          | SSH-Verbindung zu allen Nodes testen              |
| make deps          | Ansible Galaxy Collections installieren           |
| make lint          | Ansible-Linting ausfuehren                        |
| make cluster-info  | Nodes, fehlerhafte Pods und ArgoCD Apps anzeigen  |
| make argocd-password | ArgoCD Admin-Passwort ausgeben                  |
| make vault-encrypt | Beliebigen Wert mit Vault verschluesseln          |
| make vault-k3s-token | Neuen k3s-Token generieren und verschluesseln   |

---

## Sicherheitshinweise

- Das Ansible-Vault-Passwort niemals committen. Die .gitignore schliesst
  .vault_pass bereits aus.
- k3s_token ist ein geteiltes Secret zwischen den Nodes. Nur mit Vault
  verschluesselt in Git speichern.
- Port 22 (SSH) ist per UFW nur aus dem LAN erreichbar.
- Alle oeffentlich erreichbaren Dienste laufen ausschliesslich ueber HTTPS
  mit automatisch erneuertem Let's Encrypt Zertifikat.
- ArgoCD hat nur Lesezugriff auf dieses Repository.
