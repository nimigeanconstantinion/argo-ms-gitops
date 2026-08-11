# cert-manager-issuers

`ClusterIssuer` Let's Encrypt prod cu **HTTP01 challenge**.

| | |
|---|---|
| Application | `argo-apps/infra-cert-manager-issuers.yaml` |
| Tip | raw manifests (single-source path) |
| Wave | 1 (după cert-manager wave 0) |
| Namespace | `cert-manager` |

## Conținut

`clusterissuer.yaml` — `ClusterIssuer letsencrypt-prod` cu solver HTTP01 via ingress `nginx`.

## Verify

```bash
kubectl get clusterissuer letsencrypt-prod
kubectl describe clusterissuer letsencrypt-prod
# status: Ready=True, Reason=ACMEAccountRegistered
```

## HTTP01 vs DNS01

| Aspect | HTTP01 (folosit aici) | DNS01 |
|---|---|---|
| Setup | Simplu — doar `nginx-ingress` accesibil pe :80 | Necesită API token DNS provider + `SealedSecret` |
| Wildcard certs (`*.<domeniu>`) | ❌ Nu suportă | ✅ Suportă |
| Validare per subdomeniu | Necesar 1 Ingress per host | Doar DNS challenge |
| Folosit când | Subdomenii fixe, fără proxy între | Cloudflare proxy, wildcards |

## Edit hint

- `email:` schimbă cu adresa ta — primești notificări de expirare LE
- Adaugă `letsencrypt-staging` ca al doilea ClusterIssuer pentru teste (rate limits prod = 50 certs/săpt/domeniu)

## Folosire

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

Pe Ingress → cert-manager creează automat `Certificate` → `Order` → `Challenge` HTTP01 → ACK → cert TLS în `Secret`.

## Switch la DNS01 (când vrei wildcards)

1. Sigilează API token Cloudflare cu `kubeseal` în `infra/cert-manager-issuers/cloudflare-token-sealed.yaml`
2. Schimbă `solvers` în `clusterissuer.yaml`:
   ```yaml
   solvers:
     - dns01:
         cloudflare:
           apiTokenSecretRef:
             name: cloudflare-api-token
             key: api-token
   ```
3. Commit + push
