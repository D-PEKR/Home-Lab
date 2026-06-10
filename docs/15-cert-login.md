# 15 — Zertifikats-Authentifizierung mit Authentik

Passwortloses Login für alle Home-Lab-Dienste über Client-Zertifikate. Authentik
validiert das Browser-Zertifikat statt eines Passworts; alle verbundenen Apps
(OIDC oder Forward Auth) profitieren automatisch über SSO.

---

## Architektur

```
Browser (Client-Zertifikat installiert)
    │
    │  HTTPS + mTLS
    ▼
Traefik (websecure, PassTLSClientCert)
    │  Header: ssl-client-cert: <PEM>
    ▼
Authentik (Certificate Stage)
    │  OIDC-Token / Session
    ▼
Grafana · Headlamp · Argo Workflows · MinIO   ← OIDC
Gotify  · Semaphore                           ← Forward Auth
```

| Dienst | Typ | Status |
|---|---|---|
| Grafana | OIDC | ✅ bereits konfiguriert |
| Headlamp | OIDC | PR: feat/headlamp-oidc |
| Argo Workflows | OIDC SSO | PR: feat/argo-workflows-sso |
| MinIO | OIDC | PR: feat/minio-oidc |
| Gotify | Forward Auth | PR: feat/gotify-forwardauth |
| Semaphore | Forward Auth | PR: feat/semaphore-forwardauth |

---

## Voraussetzungen

- Authentik läuft im Cluster (`kubectl -n authentik get pods`)
- `kubeseal` ist lokal installiert und zeigt auf den Cluster
- `openssl` ist lokal installiert

---

## Schritt 1 — Zertifikate erstellen (lokal)

### 1.1 — CA (Certification Authority) anlegen

```bash
# Verzeichnis anlegen
mkdir -p ~/homelab-certs && cd ~/homelab-certs

# CA-Key + selbstsigniertes Zertifikat
openssl req -x509 -newkey rsa:4096 -days 3650 \
  -keyout ca.key -out ca.crt \
  -subj "/CN=Home-Lab-CA/O=HomeLab" \
  -nodes
```

### 1.2 — Client-Zertifikat für deinen Browser anlegen

```bash
cd ~/homelab-certs

# Key + Certificate Signing Request
openssl req -newkey rsa:4096 -days 3650 \
  -keyout client.key -out client.csr \
  -subj "/CN=admin/O=HomeLab/emailAddress=admin@homeserver.local" \
  -nodes

# CA signiert das Client-Zertifikat
openssl x509 -req -days 3650 \
  -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt

# PKCS12-Bundle für den Browser (wird mit Passwort geschützt)
openssl pkcs12 -export \
  -in client.crt -inkey client.key \
  -out client.p12 \
  -passout pass:   # leeres Passwort OK für lokalen Gebrauch
```

### 1.3 — Server-Zertifikat für authentik.homeserver

```bash
cd ~/homelab-certs

# Config-Datei für SAN
cat > server.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[req_distinguished_name]
CN = authentik.homeserver

[req_ext]
subjectAltName = DNS:authentik.homeserver
EOF

# Key + CSR + CA-signiertes Server-Zert
openssl req -newkey rsa:2048 -days 3650 \
  -keyout server.key -out server.csr \
  -nodes -config server.cnf

openssl x509 -req -days 3650 \
  -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt \
  -extensions req_ext -extfile server.cnf
```

---

## Schritt 2 — TLS-Secret für Traefik versiegeln

```bash
NAMESPACE=authentik
SECRET_NAME=authentik-tls

seal_file() {
  cat "$1" | kubeseal --raw \
    --namespace "$NAMESPACE" \
    --name "$SECRET_NAME" \
    --controller-namespace sealed-secrets \
    --controller-name sealed-secrets-controller \
    --from-file=/dev/stdin
}

echo "tls.crt: $(cat ~/homelab-certs/server.crt | seal_file /dev/stdin)"
echo "tls.key: $(cat ~/homelab-certs/server.key | seal_file /dev/stdin)"
```

Die Ausgabe (zwei lange Base64-Blobs) in
`argocd/apps/authentik/values.yaml` eintragen:

```yaml
tls:
  enabled: true
  encryptedCrt: "<AUSGABE tls.crt>"
  encryptedKey: "<AUSGABE tls.key>"
```

---

## Schritt 3 — CA in Authentik importieren

1. Öffne **http://authentik.homeserver/if/admin/**
2. **System → Certificates → Importieren**
3. Name: `Home-Lab-CA`
4. Certificate Data: Inhalt von `~/homelab-certs/ca.crt` einfügen
5. Private Key: **leer lassen** (nur der öffentliche Teil wird benötigt)
6. Speichern.

---

## Schritt 4 — Certificate Stage in Authentik erstellen

1. **Flows & Stages → Stages → Erstellen → Certificate Stage**
2. Werte:
   - Name: `certificate-stage`
   - Mode: `Certificate-based authentication`
   - Client Certificate Authority: `Home-Lab-CA` (aus Schritt 3)
3. Speichern.

---

## Schritt 5 — Authentik Authentication-Flow anpassen

Du hast zwei Möglichkeiten:

### Option A — Zertifikat als einzige Methode (empfohlen)

1. **Flows & Stages → Flows → default-authentication-flow bearbeiten**
2. Stage Bindings: Den `password`-Stage durch `certificate-stage` ersetzen.
3. Reihenfolge der Stages:
   ```
   1. identification-stage   (Benutzername eingeben)
   2. certificate-stage      (Browser-Zertifikat prüfen)
   ```

### Option B — Zertifikat als zusätzlicher Faktor (MFA)

1. Behalte `password-stage` als Schritt 2.
2. Füge `certificate-stage` als Schritt 3 hinzu.

---

## Schritt 6 — Traefik für mTLS konfigurieren

Die notwendigen Kubernetes-Ressourcen werden mit dem PR
**feat/authentik-cert-login** deployed:

- **TLSOption** `authentik-mtls` — fordert Client-Zertifikat beim TLS-Handshake an
- **Middleware** `authentik-passtls` — leitet das Zertifikat als Header weiter
- **Middleware** `authentik-forwardauth` — ForwardAuth für Gotify/Semaphore
- **SealedSecret** `authentik-tls` — Server-Zertifikat (muss aus Schritt 2 befüllt werden)

Nach dem Merge (und nachdem die Secrets aus Schritt 2 eingepflegt sind):

```bash
# Prüfen ob die Ressourcen deployed wurden
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik get middleware,tlsoption,sealedsecret'
```

---

## Schritt 7 — CA & Client-Zertifikat im Browser installieren

### CA-Zertifikat (einmalig, systemweit)

**Chrome/Edge (Linux):**
```
Settings → Security → Manage certificates → Authorities → Import
→ ~/homelab-certs/ca.crt → Trust for websites ✓
```

**Firefox:**
```
Settings → Privacy & Security → View Certificates → Authorities → Import
→ ~/homelab-certs/ca.crt → Trust for websites ✓
```

### Client-Zertifikat

**Chrome/Edge:**
```
Settings → Security → Manage certificates → Your certificates → Import
→ ~/homelab-certs/client.p12
```

**Firefox:**
```
Settings → Privacy & Security → View Certificates → Your Certificates → Import
→ ~/homelab-certs/client.p12
```

---

## Schritt 8 — Pro App verbinden

### Grafana ✅ (bereits konfiguriert)

Keine Änderung nötig. Grafana leitet automatisch zu Authentik weiter.
Nach dem Cert-Login bei Authentik ist Grafana direkt zugänglich.

---

### Headlamp

Voraussetzung: PR **feat/headlamp-oidc** gemergt.

#### 8.1 — Provider in Authentik anlegen

1. **Applications → Providers → Erstellen → OAuth2/OpenID Provider**
   - Name: `Headlamp`
   - Client type: `Confidential`
   - Redirect URI: `http://headlamp.homeserver/oidc-callback`
   - Scopes: `openid`, `email`, `profile`, `groups`
2. Notiere `Client ID` und `Client Secret`.
3. **Applications → Erstellen:**
   - Name: `Headlamp`, Provider: `Headlamp`

#### 8.2 — Secret versiegeln

```bash
seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace headlamp --name headlamp-oidc \
    --controller-namespace sealed-secrets \
    --controller-name sealed-secrets-controller
}

echo "clientId:     $(seal '<DEINE_CLIENT_ID>')"
echo "clientSecret: $(seal '<DEIN_CLIENT_SECRET>')"
```

Ausgabe in `argocd/apps/headlamp/templates/oidc-sealedsecret.yaml` eintragen
(Felder `encryptedClientId` und `encryptedClientSecret`).

---

### Argo Workflows

Voraussetzung: PR **feat/argo-workflows-sso** gemergt.

#### 8.3 — Provider anlegen

1. **Providers → OAuth2/OpenID Provider:**
   - Name: `Argo Workflows`
   - Redirect URI: `http://argo-workflows.homeserver/oauth2/callback`
   - Scopes: `openid`, `email`, `profile`, `groups`
2. **Applications → Erstellen:** Name `Argo Workflows`.

#### 8.4 — Secret versiegeln

```bash
seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace argo-workflows --name argo-workflows-sso \
    --controller-namespace sealed-secrets \
    --controller-name sealed-secrets-controller
}

echo "clientId:     $(seal '<CLIENT_ID>')"
echo "clientSecret: $(seal '<CLIENT_SECRET>')"
```

Ausgabe in `argocd/apps/argo-workflows/templates/sso-sealedsecret.yaml` eintragen.

---

### MinIO

Voraussetzung: PR **feat/minio-oidc** gemergt.

#### 8.5 — Provider anlegen

1. **Providers → OAuth2/OpenID Provider:**
   - Name: `MinIO`
   - Redirect URI: `http://minio.homeserver/oauth_callback`
   - Scopes: `openid`, `email`, `profile`, `groups`
2. **Applications → Erstellen:** Name `MinIO`.

#### 8.6 — Secret versiegeln

```bash
seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace minio --name minio-oidc \
    --controller-namespace sealed-secrets \
    --controller-name sealed-secrets-controller
}

echo "clientId:     $(seal '<CLIENT_ID>')"
echo "clientSecret: $(seal '<CLIENT_SECRET>')"
```

Ausgabe in `argocd/apps/minio/templates/oidc-sealedsecret.yaml` eintragen.

---

### Gotify

Voraussetzung: PR **feat/gotify-forwardauth** gemergt.

#### 8.7 — Forward-Auth-Provider anlegen

1. **Providers → Erstellen → Proxy Provider**
   - Name: `Gotify`
   - Mode: `Forward auth (single application)`
   - External Host: `http://gotify.homeserver`
2. **Applications → Erstellen:** Name `Gotify`, Provider `Gotify`.

Nach dem Merge: Gotify ist automatisch durch Authentik geschützt.

---

### Semaphore

Voraussetzung: PR **feat/semaphore-forwardauth** gemergt.

#### 8.8 — Forward-Auth-Provider anlegen

1. **Providers → Erstellen → Proxy Provider**
   - Name: `Semaphore`
   - Mode: `Forward auth (single application)`
   - External Host: `http://semaphore.homeserver`
2. **Applications → Erstellen:** Name `Semaphore`, Provider `Semaphore`.

---

### ArgoCD (manuell, nicht via GitOps)

ArgoCD wird per Ansible bootstrapped und ist nicht als ArgoCD-App verwaltet.
OIDC muss daher direkt als ConfigMap angewendet werden.

#### 8.9 — Provider anlegen

- Redirect URI: `http://192.168.178.94:30080/auth/callback`
- Scopes: `openid`, `email`, `profile`, `groups`

#### 8.10 — argocd-cm & argocd-secret patchen

```bash
# Client-Secret als Kubernetes-Secret anlegen (VERSCHLÜSSELN!)
kubectl -n argocd create secret generic argocd-secret \
  --from-literal=oidc.authentik.clientSecret='<CLIENT_SECRET>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller -o yaml \
  | kubectl apply -f -

# argocd-cm mit OIDC-Konfiguration patchen
kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: "http://192.168.178.94:30080"
  oidc.config: |
    name: Authentik
    issuer: http://authentik.homeserver/application/o/argocd/
    clientID: <CLIENT_ID>
    clientSecret: \$oidc.authentik.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    g, authentik Admins, role:admin
EOF
```

---

## Schritt 9 — Testen

```bash
# 1. Authentik erreichbar (jetzt HTTPS)
curl -k https://authentik.homeserver/if/flow/default-authentication-flow/

# 2. Prüfen ob Middleware deployed
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik get middleware'

# 3. Grafana öffnen → Browser fragt nach Zertifikat → automatisch eingeloggt
open http://grafana.homeserver

# 4. Gotify öffnen → Weiterleitung zu Authentik → Cert-Login → Gotify
open http://gotify.homeserver
```

---

## Troubleshooting

### Browser fragt nicht nach Zertifikat

- CA und Client-Zertifikat in den Browser-Trust-Store importiert? (→ Schritt 7)
- Authentik wirklich über HTTPS erreichbar (`https://authentik.homeserver`)?
- TLSOption deployed? `kubectl -n authentik get tlsoption`

### `ssl-client-cert` Header fehlt in Authentik

- PassTLSClientCert-Middleware an der Route aktiv?
- Traefik-Logs prüfen: `kubectl -n kube-system logs -l app.kubernetes.io/name=traefik`

### Certificate Stage sagt "invalid certificate"

- CA in Authentik korrekt importiert? (`System → Certificates`)
- Client-Zertifikat mit der richtigen CA signiert?
- Ablaufdatum prüfen: `openssl x509 -in ~/homelab-certs/client.crt -noout -dates`

### Gotify/Semaphore zeigt leere Seite nach Login

- Proxy-Provider in Authentik konfiguriert? (`Applications → Providers`)
- Embedded Outpost läuft? `kubectl -n authentik get pods`
- Middleware-Name korrekt? Format: `authentik-authentik-forwardauth@kubernetescrd`

---

## Weiterführende Links

- [Authentik Certificate Stage Docs](https://docs.goauthentik.io/docs/flow/stages/identification/)
- [Traefik PassTLSClientCert](https://doc.traefik.io/traefik/middlewares/http/passtlsclientcert/)
- [Traefik TLSOptions](https://doc.traefik.io/traefik/https/tls/#tls-options)
