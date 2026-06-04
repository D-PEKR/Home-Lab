# Design: Wildcard-DNS für `*.homeserver`

_Datum: 2026-05-22_

## Problem

Neue ArgoCD-Apps mit Ingress sind im Homelab (LAN + Tailnet) nicht automatisch per DNS erreichbar. Jede neue App erfordert bisher:
1. Eintrag in `dnsmasq_hosts` in `ansible/group_vars/all.yml`
2. Ausführen von `make dnsmasq`

## Ziel

Jede App, die mit einem `*.homeserver`-Ingress im Cluster deployed wird, ist ohne manuellen Schritt sofort per DNS erreichbar.

## Entscheidung

**Wildcard-DNS-Eintrag in dnsmasq** statt expliziter Einträge pro Service.

Verworfene Alternativen:
- **ExternalDNS**: Community-Support für dnsmasq, nicht offiziell — zu komplex für den Mehrwert.
- **Ansible-Sync-Script**: Halbautomatisch, viele bewegliche Teile, Verzögerung durch Scheduling.

## Änderungen

### `ansible/roles/dnsmasq/templates/dnsmasq.conf.j2`

Die `{% for host in dnsmasq_hosts %}`-Schleife entfällt. Ersatz:

```
address=/homeserver/{{ network_static_ip }}
```

dnsmasq matcht damit `homeserver` und alle Subdomains (`*.homeserver`) → `network_static_ip`. Traefik routet den eingehenden Traffic per Ingress-Hostname zum richtigen Service.

### `ansible/group_vars/all.yml`

Der `dnsmasq_hosts:`-Block wird entfernt. Die Variable ist nach der Änderung unbenutzt.

## Was sich nicht ändert

- dnsmasq lauscht weiterhin auf der statischen LAN-IP und auf `tailscale0`
- LAN- und Tailnet-Clients werden identisch behandelt
- Traefik/k3s-Ingress-Routing bleibt unverändert
- Nicht existierende `*.homeserver`-Namen lösen auf die Server-IP auf — Traefik antwortet mit 404 (akzeptables Verhalten im Homelab)

## Deploy

```bash
make dnsmasq
```

dnsmasq wird mit der neuen Konfiguration neu gestartet. Kein weiterer Schritt nötig.
