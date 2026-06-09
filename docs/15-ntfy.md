# ntfy — Self-hosted Push-Notifications mit iOS-Support

ntfy ist ein einfacher, selbst gehosteter Pub/Sub-Notification-Dienst. Im Gegensatz zu Gotify unterstützt ntfy **echte iOS-Push-Nachrichten** über Apple Push Notification Service (APNs), indem es Nachrichten über das ntfy.sh-Relay weiterleitet.

## Warum ntfy statt Gotify für iOS?

| | Gotify | ntfy |
|---|---|---|
| Android | ✓ nativ | ✓ nativ |
| iOS | ✗ (WebSocket, kein Background-Push) | ✓ (APNs via upstream-Relay) |
| Self-hosted | ✓ | ✓ |
| Auth | ✓ | ✓ (optional) |
| HTTP-API | ✓ | ✓ |

**Empfehlung:** Gotify für interne Logs/Scanner-Status behalten; ntfy für iOS-Benachrichtigungen nutzen.

## Architektur

```
Scanner / ArgoCD-Alert / beliebiger curl-Sender
        │
        ▼
ntfy-Server (http://ntfy.homeserver)
        │
        ├── Android-App (direkt via WebSocket)
        │
        └── ntfy.sh-Relay ──► Apple APNs ──► iOS-App
```

Das `upstream-base-url: https://ntfy.sh` in der Konfiguration aktiviert diesen Relay. Die Nachrichteninhalte verlassen dabei deinen Server im Klartext in Richtung ntfy.sh — für sensible Daten ggf. End-to-End-Verschlüsselung aktivieren (siehe unten).

## Deployment

ArgoCD deployt ntfy automatisch sobald der Branch auf `main` gemergt ist:

```
argocd/apps/ntfy/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── configmap.yaml      # server.yml
    ├── deployment.yaml
    ├── ingress.yaml
    ├── pvc.yaml
    ├── service.yaml
    └── serviceaccount.yaml
```

URL nach dem Deployment: **http://ntfy.homeserver**

## iOS einrichten

1. **ntfy-App** aus dem [App Store](https://apps.apple.com/app/ntfy/id1625396347) installieren
2. App öffnen → **+** → Server-URL eintragen: `http://ntfy.homeserver`
3. Topic abonnieren z.B. `homeserver` oder `scanner`
4. Benachrichtigungen in den iOS-Einstellungen für ntfy erlauben

> **Hinweis:** Das Topic ist öffentlich zugänglich solange `auth-default-access: read-write` gesetzt ist. Für private Topics Auth aktivieren (siehe unten).

## Nachrichten senden

### Einfachste Form
```bash
curl -d "Scan fertig" http://ntfy.homeserver/scanner
```

### Mit Titel und Priorität
```bash
curl \
  -H "Title: Home-Server Alert" \
  -H "Priority: high" \
  -H "Tags: warning" \
  -d "Festplatte > 90% voll" \
  http://ntfy.homeserver/homeserver
```

### Prioritäten
| Wert | Bedeutung |
|---|---|
| `min` / `1` | Stumm |
| `low` / `2` | Leise |
| `default` / `3` | Normal |
| `high` / `4` | Laut |
| `urgent` / `5` | Dringend, DND wird ignoriert |

### Tags (Emoji-Icons in der App)
```bash
-H "Tags: white_check_mark"   # ✅
-H "Tags: warning"             # ⚠️
-H "Tags: rotating_light"      # 🚨
```

Vollständige Emoji-Liste: https://docs.ntfy.sh/emojis/

## Scanner-Integration

In `ansible/roles/scanner/templates/scan_to_pdf.sh.j2` zusätzlich zu Gotify an ntfy senden:

```bash
# ntfy-Benachrichtigung (iOS)
curl -s \
  -H "Title: Scanner" \
  -H "Tags: white_check_mark" \
  -d "Scan fertig: ${FILENAME}" \
  http://ntfy.homeserver/scanner || true
```

## dnsmasq-Eintrag

ntfy.homeserver muss in der dnsmasq-Konfiguration ergänzt werden. In `ansible/group_vars/all.yml`:

```yaml
dnsmasq_hosts:
  # ... bestehende Einträge ...
  - name: ntfy
    ip: 192.168.178.94
```

Danach `make dnsmasq` ausführen.

## Authentifizierung aktivieren (optional)

Wenn Topics nicht öffentlich sein sollen, in `values.yaml` ändern:

```yaml
config:
  auth-default-access: "deny-all"
```

Dann User anlegen (SSH auf den Server, kubectl exec):

```bash
kubectl -n ntfy exec -it deploy/ntfy -- ntfy user add --role=admin admin
kubectl -n ntfy exec -it deploy/ntfy -- ntfy user add publisher
kubectl -n ntfy exec -it deploy/ntfy -- ntfy access publisher homeserver rw
```

Nachrichten dann mit Basic Auth senden:

```bash
curl -u publisher:PASSWORT -d "Test" http://ntfy.homeserver/homeserver
```

## End-to-End-Verschlüsselung (optional)

Wenn Nachrichten über ntfy.sh-Relay nicht im Klartext weitergeleitet werden sollen:

```bash
# Lokal verschlüsseln (ntfy CLI)
ntfy publish --password "geheim" http://ntfy.homeserver/homeserver "Meine Nachricht"
```

In der iOS-App: Topic-Einstellungen → Passwort eintragen.

## Troubleshooting

### Pod startet nicht
```bash
kubectl -n ntfy get pods
kubectl -n ntfy logs deploy/ntfy
```

### iOS-Benachrichtigungen kommen nicht an
1. Prüfen ob `upstream-base-url: https://ntfy.sh` in der ConfigMap gesetzt ist:
   ```bash
   kubectl -n ntfy get configmap ntfy-config -o yaml
   ```
2. Prüfen ob der Pod Internetzugang hat (ntfy.sh muss erreichbar sein):
   ```bash
   kubectl -n ntfy exec deploy/ntfy -- wget -q -O- https://ntfy.sh/v1/health
   ```
3. iOS-Benachrichtigungen in Einstellungen → ntfy → Mitteilungen prüfen

### Nachrichten testen
```bash
# Direkt vom Cluster aus
kubectl -n ntfy exec deploy/ntfy -- \
  wget -q -O- --post-data="Test von kubectl" http://localhost:8080/test
```
