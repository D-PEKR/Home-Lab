# 15 — Zertifikats-Authentifizierung via Traefik mTLS

Client-Zertifikate als Zugangsschutz für alle Home-Lab-Dienste. Traefik prüft das
Browser-Zertifikat direkt gegen die eigene CA — kein Authentik Enterprise-Feature
nötig. Nur Geräte mit gültigem Zertifikat können die Dienste überhaupt erreichen;
Authentik übernimmt weiterhin Identität und SSO.

---

## Architektur

```
Browser (Client-Zertifikat installiert)
    │
    │  HTTPS + mTLS (TLS-Handshake)
    ▼
Traefik (TLSOption: RequireAndVerifyClientCert → Home-Lab-CA)
    │  Ungültiges / fehlendes Zert → 400 Bad Request, kein Request weiter
    ▼
Authentik (Login: Benutzername + Passwort / TOTP wie bisher)
    │  OIDC-Token / Session / ForwardAuth
    ▼
Grafana · Headlamp · Argo Workflows · MinIO   ← OIDC
Gotify  · Semaphore                           ← Forward Auth
```

**Was das Zertifikat tut:** Netzwerk-Zugangskontrolle — nur Geräte mit
CA-signiertem Zertifikat können die Dienste überhaupt kontaktieren.

**Was das Zertifikat NICHT tut:** Es ersetzt nicht den Authentik-Login.
Benutzername + Passwort (oder TOTP) bleibt der Identity-Schritt.

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
- `kubeseal` ist lokal installiert
- `openssl` ist lokal installiert
- Public Key des Sealed-Secrets-Controllers liegt lokal vor (siehe Hinweis unten)

### kubeseal ohne lokalen Cluster-Kontext

Da dein lokales kubeconfig nicht auf den Home-Server zeigt, Public Key einmalig
vom Server holen und für alle `kubeseal`-Befehle verwenden:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.178.94 \
  'sudo kubectl -n sealed-secrets get secret \
   -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
   -o jsonpath="{.items[0].data.tls\.crt}" | base64 -d' \
  > ~/homelab-certs/sealed-secrets.pem
```

Alle `kubeseal`-Befehle in dieser Anleitung nutzen `--cert ~/homelab-certs/sealed-secrets.pem`
statt einer Live-Verbindung zum Controller.

---

## Schritt 1 — Zertifikate erstellen (lokal)

### 1.1 — CA (Certification Authority) anlegen

```bash
mkdir -p ~/homelab-certs && cd ~/homelab-certs

openssl req -x509 -newkey rsa:4096 -days 3650 \
  -keyout ca.key -out ca.crt \
  -subj "/CN=Home-Lab-CA/O=HomeLab" \
  -nodes
```

### 1.2 — Client-Zertifikat für deinen Browser anlegen

```bash
cd ~/homelab-certs

openssl req -newkey rsa:4096 -days 3650 \
  -keyout client.key -out client.csr \
  -subj "/CN=admin/O=HomeLab/emailAddress=admin@homeserver.local" \
  -nodes

openssl x509 -req -days 3650 \
  -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt

# PKCS12-Bundle für den Browser
openssl pkcs12 -export \
  -in client.crt -inkey client.key \
  -out client.p12 \
  -passout pass:   # leeres Passwort OK für lokalen Gebrauch
```

### 1.3 — Server-Zertifikat für authentik.homeserver

```bash
cd ~/homelab-certs

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

openssl req -newkey rsa:2048 -days 3650 \
  -keyout server.key -out server.csr \
  -nodes -config server.cnf

openssl x509 -req -days 3650 \
  -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt \
  -extensions req_ext -extfile server.cnf
```

---

## Schritt 2 — Secrets versiegeln

### 2.1 — Server-TLS für Authentik

```bash
NAMESPACE=authentik
SECRET_NAME=authentik-tls

seal_file() {
  kubeseal --raw \
    --namespace "$NAMESPACE" \
    --name "$SECRET_NAME" \
    --cert ~/homelab-certs/sealed-secrets.pem \
    --from-file=/dev/stdin < "$1"
}

echo "tls.crt: $(seal_file ~/homelab-certs/server.crt)"
echo "tls.key: $(seal_file ~/homelab-certs/server.key)"
```

Ausgabe in `argocd/apps/authentik/values.yaml` eintragen:

```yaml
tls:
  enabled: true
  encryptedCrt: "<AUSGABE tls.crt>"
  encryptedKey: "<AUSGABE tls.key>"
```

### 2.2 — CA-Zertifikat für Traefik

Traefik braucht die CA als Kubernetes Secret, um Client-Zertifikate zu verifizieren.
Das Secret muss im selben Namespace wie die TLSOption liegen (`kube-system`).

```bash
NAMESPACE=kube-system
SECRET_NAME=homelab-ca

echo "tls.ca: $(kubeseal --raw \
  --namespace "$NAMESPACE" \
  --name "$SECRET_NAME" \
  --cert ~/homelab-certs/sealed-secrets.pem \
  --from-file=/dev/stdin < ~/homelab-certs/ca.crt)"
```

Den ausgegebenen Blob in `argocd/apps/traefik-mtls/sealedsecret-ca.yaml` eintragen:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: homelab-ca
  namespace: kube-system
spec:
  encryptedData:
    tls.ca: "<AUSGABE tls.ca>"
  template:
    metadata:
      name: homelab-ca
      namespace: kube-system
    type: Opaque
```

---

## Schritt 3 — Traefik TLSOption deployen

Erstelle `argocd/apps/traefik-mtls/` mit folgenden Dateien:

### tlsoption.yaml

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: mtls-homelab
  namespace: kube-system
spec:
  minVersion: VersionTLS12
  clientAuth:
    secretNames:
      - homelab-ca          # Secret aus Schritt 2.2
    clientAuthType: RequireAndVerifyClientCert
```

### kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sealedsecret-ca.yaml
  - tlsoption.yaml
```

Nach dem Commit und ArgoCD-Sync prüfen:

```bash
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n kube-system get tlsoption mtls-homelab && \
   sudo kubectl -n kube-system get secret homelab-ca'
```

---

## Schritt 4 — IngressRoutes auf mTLS umstellen

Für jeden Dienst muss die IngressRoute die TLSOption referenzieren.
Beispiel für Authentik (`argocd/apps/authentik/ingressroute.yaml`):

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: authentik
  namespace: authentik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`authentik.homeserver`)
      kind: Rule
      services:
        - name: authentik
          port: 9000
  tls:
    options:
      name: mtls-homelab
      namespace: kube-system    # TLSOption liegt in kube-system
```

Das gleiche `tls.options`-Block für alle anderen IngressRoutes ergänzen:
Grafana, Headlamp, Argo Workflows, MinIO, Gotify, Semaphore.

---

## Schritt 5 — CA & Client-Zertifikat im Browser installieren

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

## Schritt 6 — Pro App verbinden

### Grafana ✅ (bereits konfiguriert)

Keine Änderung nötig. Nach Cert-Check durch Traefik leitet Grafana automatisch
zu Authentik weiter.

---

### Headlamp

Voraussetzung: PR **feat/headlamp-oidc** gemergt.

#### 6.1 — Provider in Authentik anlegen

1. **Applications → Providers → Erstellen → OAuth2/OpenID Provider**
   - Name: `Headlamp`
   - Client type: `Confidential`
   - Redirect URI: `http://headlamp.homeserver/oidc-callback`
   - Scopes: `openid`, `email`, `profile`, `groups`
2. Notiere `Client ID` und `Client Secret`.
3. **Applications → Erstellen:** Name `Headlamp`, Provider `Headlamp`

#### 6.2 — Secret versiegeln

```bash
seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace headlamp --name headlamp-oidc \
    --cert ~/homelab-certs/sealed-secrets.pem
}

echo "clientId:     $(seal '<DEINE_CLIENT_ID>')"
echo "clientSecret: $(seal '<DEIN_CLIENT_SECRET>')"
```

Ausgabe in `argocd/apps/headlamp/templates/oidc-sealedsecret.yaml` eintragen
(Felder `encryptedClientId` und `encryptedClientSecret`).

---

### Argo Workflows

Voraussetzung: PR **feat/argo-workflows-sso** gemergt.

#### 6.3 — Provider anlegen

1. **Providers → OAuth2/OpenID Provider:**
   - Name: `Argo Workflows`
   - Redirect URI: `http://argo-workflows.homeserver/oauth2/callback`
   - Scopes: `openid`, `email`, `profile`, `groups`
2. **Applications → Erstellen:** Name `Argo Workflows`.

#### 6.4 — Secret versiegeln

```bash
seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace argo-workflows --name argo-workflows-sso \
    --cert ~/homelab-certs/sealed-secrets.pem
}

echo "clientId:     $(seal '<CLIENT_ID>')"
echo "clientSecret: $(seal '<CLIENT_SECRET>')"
```

Ausgabe in `argocd/apps/argo-workflows/templates/sso-sealedsecret.yaml` eintragen.

---

### MinIO

Voraussetzung: PR **feat/minio-oidc** gemergt.

#### 6.5 — Provider anlegen

1. **Providers → OAuth2/OpenID Provider:**
   - Name: `MinIO`
   - Redirect URI: `http://minio.homeserver/oauth_callback`
   - Scopes: `openid`, `email`, `profile`, `groups`
2. **Applications → Erstellen:** Name `MinIO`.

#### 6.6 — Secret versiegeln

```bash
seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace minio --name minio-oidc \
    --cert ~/homelab-certs/sealed-secrets.pem
}

echo "clientId:     $(seal '<CLIENT_ID>')"
echo "clientSecret: $(seal '<CLIENT_SECRET>')"
```

Ausgabe in `argocd/apps/minio/templates/oidc-sealedsecret.yaml` eintragen.

---

### Gotify

Voraussetzung: PR **feat/gotify-forwardauth** gemergt.

#### 6.7 — Forward-Auth-Provider anlegen

1. **Providers → Erstellen → Proxy Provider**
   - Name: `Gotify`
   - Mode: `Forward auth (single application)`
   - External Host: `http://gotify.homeserver`
2. **Applications → Erstellen:** Name `Gotify`, Provider `Gotify`.

---

### Semaphore

Voraussetzung: PR **feat/semaphore-forwardauth** gemergt.

#### 6.8 — Forward-Auth-Provider anlegen

1. **Providers → Erstellen → Proxy Provider**
   - Name: `Semaphore`
   - Mode: `Forward auth (single application)`
   - External Host: `http://semaphore.homeserver`
2. **Applications → Erstellen:** Name `Semaphore`, Provider `Semaphore`.

---

### ArgoCD (manuell, nicht via GitOps)

#### 6.9 — Provider anlegen

- Redirect URI: `http://192.168.178.94:30080/auth/callback`
- Scopes: `openid`, `email`, `profile`, `groups`

#### 6.10 — argocd-cm & argocd-secret patchen

```bash
kubectl -n argocd create secret generic argocd-secret \
  --from-literal=oidc.authentik.clientSecret='<CLIENT_SECRET>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller -o yaml \
  | kubectl apply -f -

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

## Schritt 7 — Testen

```bash
# 1. TLSOption und CA-Secret deployed
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n kube-system get tlsoption mtls-homelab && \
   sudo kubectl -n kube-system get secret homelab-ca'

# 2. Zugriff mit Client-Zertifikat funktioniert
curl --cert ~/homelab-certs/client.crt \
     --key  ~/homelab-certs/client.key \
     --cacert ~/homelab-certs/ca.crt \
     https://authentik.homeserver/if/flow/default-authentication-flow/

# 3. Zugriff OHNE Zertifikat wird abgelehnt (muss 400 zurückgeben)
curl --cacert ~/homelab-certs/ca.crt \
     https://authentik.homeserver/  # erwartet: 400 Bad Request

# 4. Browser: Grafana öffnen → Browser fragt nach Zertifikat → Authentik-Login
open http://grafana.homeserver
```

---

## Troubleshooting

### Browser fragt nicht nach Zertifikat

- CA und Client-Zertifikat im Browser-Trust-Store? (→ Schritt 5)
- TLSOption deployed? `kubectl -n kube-system get tlsoption mtls-homelab`
- IngressRoute referenziert die TLSOption? (`tls.options.name: mtls-homelab`)

### 400 Bad Request ohne Fehlermeldung

Traefik hat den mTLS-Handshake abgelehnt — Browser hat kein oder ein ungültiges
Zertifikat gesendet. Client-Zertifikat korrekt im Browser importiert?

### CA-Secret fehlt / TLSOption ignoriert Client-Certs

```bash
# Secret-Inhalt prüfen
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n kube-system get secret homelab-ca -o jsonpath="{.data.tls\.ca}" \
   | base64 -d | openssl x509 -noout -subject'
```

Muss `/CN=Home-Lab-CA/O=HomeLab` ausgeben.

### Traefik-Logs zeigen TLS-Fehler

```bash
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=50'
```

### Client-Zertifikat abgelaufen

```bash
openssl x509 -in ~/homelab-certs/client.crt -noout -dates
```

### Gotify/Semaphore zeigt leere Seite nach Login

- Proxy-Provider in Authentik konfiguriert? (`Applications → Providers`)
- Embedded Outpost läuft? `kubectl -n authentik get pods`
- Middleware-Name korrekt? Format: `authentik-authentik-forwardauth@kubernetescrd`

---

## Weiterführende Links

- [Traefik TLSOptions Docs](https://doc.traefik.io/traefik/https/tls/#tls-options)
- [Traefik mTLS / Client Authentication](https://doc.traefik.io/traefik/https/tls/#client-authentication-mtls)
- [Kubernetes SealedSecrets](https://github.com/bitnami-labs/sealed-secrets)
