# 14 — Single Sign-On mit Authentik

Authentik ist ein Open-Source Identity Provider (IdP). Er stellt OIDC/OAuth2 bereit, sodass du dich einmal anmeldest und danach automatisch in allen Home-Lab-Diensten eingeloggt bist.

---

## Architektur

```
Browser  →  Traefik  →  authentik.homeserver  (Authentik)
                              ↕ OIDC/OAuth2
          Grafana · ArgoCD · Headlamp · Argo Workflows · MinIO
                              ↕ Forward Auth (Traefik-Middleware)
                         Gotify · Semaphore
```

| Dienst | Integrations-Typ | Authentik-Vorlage |
|---|---|---|
| Grafana | OIDC OAuth2 | — |
| ArgoCD | OIDC (extern) | — |
| Headlamp | OIDC | — |
| Argo Workflows | OIDC SSO | — |
| MinIO | OpenID Connect | — |
| Gotify | Forward Auth (Traefik) | Proxy Provider |
| Semaphore | Forward Auth (Traefik) | Proxy Provider |

---

## Schritt 1 — Secrets versiegeln

Vor dem ersten Deployment müssen die Credentials mit `kubeseal` versiegelt werden. Der kubeseal-Controller läuft im Namespace `sealed-secrets` auf dem Cluster.

### 1.1 — Secret-Key generieren

```bash
# 50-stelligen zufälligen String erzeugen
SECRET_KEY=$(openssl rand -hex 25)
echo "Dein secret_key: $SECRET_KEY"

# Versiegeln (von der Workstation aus, kubeconfig muss auf den Cluster zeigen)
echo -n "$SECRET_KEY" | kubeseal --raw \
  --namespace authentik \
  --name authentik-credentials \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets
```

### 1.2 — Alle vier Werte versiegeln

```bash
NAMESPACE=authentik
SECRET_NAME=authentik-credentials
CTRL_NS=sealed-secrets
CTRL_NAME=sealed-secrets

seal() {
  echo -n "$1" | kubeseal --raw \
    --namespace "$NAMESPACE" \
    --name "$SECRET_NAME" \
    --controller-namespace "$CTRL_NS" \
    --controller-name "$CTRL_NAME"
}

# Werte erzeugen
SECRET_KEY=$(openssl rand -hex 25)
DB_PASSWORD=$(openssl rand -base64 18)
BOOTSTRAP_PASSWORD=$(openssl rand -base64 18)
BOOTSTRAP_EMAIL="admin@homeserver.local"

echo "=== Für values.yaml ==="
echo "encryptedSecretKey:         $(seal "$SECRET_KEY")"
echo "encryptedDbPassword:        $(seal "$DB_PASSWORD")"
echo "encryptedBootstrapPassword: $(seal "$BOOTSTRAP_PASSWORD")"
echo "encryptedBootstrapEmail:    $(seal "$BOOTSTRAP_EMAIL")"
```

### 1.3 — values.yaml befüllen

Die Ausgabe aus 1.2 in `argocd/apps/authentik/values.yaml` eintragen:

```yaml
credentials:
  enabled: true
  secretName: authentik-credentials
  encryptedSecretKey: "<Ausgabe seal SECRET_KEY>"
  encryptedDbPassword: "<Ausgabe seal DB_PASSWORD>"
  encryptedBootstrapPassword: "<Ausgabe seal BOOTSTRAP_PASSWORD>"
  encryptedBootstrapEmail: "<Ausgabe seal BOOTSTRAP_EMAIL>"
```

> **Wichtig:** Niemals Klartext-Werte in values.yaml committen — nur die versiegelten Ciphertext-Blobs.

---

## Schritt 2 — Deployment via ArgoCD

Nach dem Commit auf `main` erkennt ArgoCD das neue `argocd/apps/authentik/`-Verzeichnis innerhalb von ca. 3 Minuten und synct automatisch.

```bash
# Manuell auslösen:
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n argocd patch application authentik \
   -p "{\"operation\":{\"sync\":{}}}" --type merge'

# Status prüfen:
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik get pods'
```

Authentik ist danach erreichbar unter: **http://authentik.homeserver**

---

## Schritt 3 — Erster Login & Admin-Setup

1. Öffne **http://authentik.homeserver/if/flow/initial-setup/**
2. Melde dich mit der `BOOTSTRAP_EMAIL` und `BOOTSTRAP_PASSWORD` an.
3. Ändere das Passwort beim ersten Login.

---

## Schritt 4 — OIDC-Integration: Grafana

### 4.1 — OAuth2-Provider in Authentik anlegen

In der Authentik Admin-UI (**http://authentik.homeserver/if/admin/**):

1. **Applications → Providers → Erstellen → OAuth2/OpenID Provider**
2. Werte:
   - Name: `Grafana`
   - Client type: `Confidential`
   - Redirect URIs: `http://grafana.homeserver/login/generic_oauth`
   - Scopes: `openid`, `email`, `profile`
3. Notiere `Client ID` und `Client Secret`.
4. **Applications → Erstellen**:
   - Name: `Grafana`
   - Provider: `Grafana`
   - Launch URL: `http://grafana.homeserver`

### 4.2 — Grafana-Values aktualisieren

In `argocd/apps/monitoring/values.yaml` unter `victoria-metrics-k8s-stack.grafana`:

```yaml
grafana:
  grafana.ini:
    server:
      domain: grafana.homeserver
      root_url: "http://grafana.homeserver"
    auth.generic_oauth:
      enabled: true
      name: "Authentik"
      icon: "signin"
      allow_sign_up: true
      auto_login: true
      client_id: "<CLIENT_ID_AUS_AUTHENTIK>"
      client_secret: "<CLIENT_SECRET_AUS_AUTHENTIK>"
      scopes: "openid email profile"
      auth_url: "http://authentik.homeserver/application/o/authorize/"
      token_url: "http://authentik.homeserver/application/o/token/"
      api_url: "http://authentik.homeserver/application/o/userinfo/"
      groups_attribute_path: "groups"
      role_attribute_path: "contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'"
```

> `auto_login: true` sorgt dafür, dass Grafana automatisch zu Authentik weiterleitet, ohne den eigenen Login-Screen zu zeigen.

**Warnung:** Das `client_secret` nicht im Klartext committen! Nutze ein SealedSecret und referenziere es via `envFrom` / `extraSecretMounts`.

---

## Schritt 5 — OIDC-Integration: ArgoCD

ArgoCD hat einen eingebauten Dex OIDC-Connector. Für externe Provider diesen deaktivieren.

### 5.1 — Authentik-Provider anlegen

Analog zu Schritt 4.1:
- Name: `ArgoCD`
- Redirect URI: `http://192.168.178.94:30080/auth/callback`
- Scopes: `openid`, `email`, `profile`, `groups`

### 5.2 — ArgoCD ConfigMap

In `argocd/apps/argocd/` (falls du eine eigene App-Konfiguration hast) oder direkt als ConfigMap:

```yaml
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
    clientSecret: $oidc.authentik.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
    requestedIDTokenClaims:
      groups:
        essential: true
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
```

Das `clientSecret` als Kubernetes Secret hinterlegen:

```bash
kubectl -n argocd create secret generic argocd-secret \
  --from-literal=oidc.authentik.clientSecret='<CLIENT_SECRET>' \
  --dry-run=client -o yaml | kubeseal \
  --controller-namespace sealed-secrets -o yaml
```

---

## Schritt 6 — OIDC-Integration: Headlamp

### 6.1 — Provider anlegen

- Redirect URI: `http://headlamp.homeserver/oidc-callback`

### 6.2 — Headlamp-Values

In `argocd/apps/headlamp/values.yaml`:

```yaml
headlamp:
  config:
    oidc:
      clientID: "<CLIENT_ID>"
      clientSecret: "<CLIENT_SECRET>"
      issuerURL: "http://authentik.homeserver/application/o/headlamp/"
      scopes: "openid,email,profile,groups"
```

---

## Schritt 7 — OIDC-Integration: MinIO

Im MinIO-Helm-Chart oder in der MinIO-Konsole (**http://minio.homeserver**):

**Konfiguration → Identity → OpenID:**
- Config URL: `http://authentik.homeserver/application/o/minio/.well-known/openid-configuration`
- Client ID: `<CLIENT_ID>`
- Client Secret: `<CLIENT_SECRET>`
- Claim Name: `groups`
- Redirect URI: `http://minio.homeserver/oauth_callback`

---

## Schritt 8 — Forward Auth: Gotify & Semaphore

Für Dienste ohne native OIDC-Unterstützung übernimmt Traefik die Authentifizierung via Forward Auth.

### 8.1 — Authentik Proxy Provider anlegen

In der Authentik Admin-UI für jeden Dienst:

1. **Providers → Erstellen → Proxy Provider**
2. Modus: `Forward auth (single application)`
3. External Host: z.B. `http://gotify.homeserver`
4. **Application anlegen** und Provider zuweisen.

### 8.2 — Traefik-Middleware deployen

Lege eine gemeinsame Middleware an (z.B. in einem eigenen Namespace oder als Teil der Authentik-App):

```yaml
# argocd/apps/authentik/templates/traefik-middleware.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forwardauth
  namespace: authentik
spec:
  forwardAuth:
    address: "http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik"
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
      - X-authentik-jwt
      - X-authentik-meta-jwks
      - X-authentik-meta-outpost
      - X-authentik-meta-provider
      - X-authentik-meta-app
      - X-authentik-meta-version
```

### 8.3 — Ingress-Annotation für geschützte Dienste

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: "authentik-authentik-forwardauth@kubernetescrd"
```

> Der Middleware-Name folgt dem Schema `<namespace>-<name>@kubernetescrd`.

---

## Argo Workflows

Argo Workflows unterstützt OIDC nativ. Im `argocd/apps/argo-workflows/values.yaml`:

```yaml
argo-workflows:
  server:
    extraArgs:
      - --auth-mode=sso
    sso:
      issuer: "http://authentik.homeserver/application/o/argo-workflows/"
      clientId:
        name: argo-workflows-sso
        key: clientId
      clientSecret:
        name: argo-workflows-sso
        key: clientSecret
      redirectUrl: "http://argo-workflows.homeserver/oauth2/callback"
      scopes:
        - openid
        - profile
        - email
        - groups
      rbac:
        enabled: true
```

---

## Troubleshooting

### Authentik-Pod startet nicht

```bash
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik describe pod -l app.kubernetes.io/component=server'

# Häufigste Ursachen:
# 1. SealedSecret nicht entschlüsselt → sealed-secrets-controller prüfen
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n sealed-secrets logs -l app.kubernetes.io/name=sealed-secrets'

# 2. PostgreSQL startet nicht → PVC-Problem?
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik get pvc'
```

### OIDC-Login schlägt fehl ("invalid_client")

- Client ID / Secret in den Grafana/ArgoCD-Werten mit Authentik vergleichen.
- Redirect URI in Authentik muss **exakt** mit der konfigurierten URL übereinstimmen (inkl. Protokoll und Pfad).
- Browser-Entwicklertools → Network-Tab → OIDC-Request prüfen.

### Grafana leitet nicht automatisch zu Authentik weiter

`auto_login: true` funktioniert nur, wenn genau ein OAuth2-Provider konfiguriert ist. Lokale Logins werden dann komplett deaktiviert. Notfall-Zugang über:

```bash
# Grafana-Pod direkt ansteuern (ohne OIDC)
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n monitoring exec -it \
   $(sudo kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana -o name) \
   -- grafana-cli admin reset-admin-password NEUES_PASSWORT'
```

### Authentik-Admin-Passwort vergessen

Das Bootstrap-Passwort gilt nur beim ersten Start. Danach zurücksetzen über:

```bash
ssh ubuntu@192.168.178.94 \
  'sudo kubectl -n authentik exec -it \
   $(sudo kubectl -n authentik get pod -l app.kubernetes.io/component=server -o name) \
   -- ak create_recovery_key 1 akadmin'
```

---

## Weiterführende Links

- [Authentik Helm-Chart Docs](https://docs.goauthentik.io/docs/installation/kubernetes)
- [Authentik Grafana-Integration](https://docs.goauthentik.io/integrations/services/grafana/)
- [Authentik ArgoCD-Integration](https://docs.goauthentik.io/integrations/services/argo-cd/)
- [Authentik Traefik Forward Auth](https://docs.goauthentik.io/docs/providers/proxy/server_traefik)
