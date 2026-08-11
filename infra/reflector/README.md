# reflector

Emberstack Reflector — replică automat `Secret`/`ConfigMap` între namespace-uri.

| | |
|---|---|
| Application | `argo-apps/infra-reflector.yaml` |
| Chart | `emberstack/reflector` 9.1.21 |
| Namespace | `reflector` |
| Wave | 0 |

## Caz de folosire

- `postgres-keycloak-credentials` în `ns: data` → vrei o copie în `ns: auth` pentru Keycloak
- TLS wildcard cert emis în `ns: ingress-nginx` → vrei copie în multiple ns-uri ale aplicațiilor
- `ConfigMap` cu certificat CA in `ns: cert-manager` → vrei în toate ns-urile aplicațiilor

## Verify

```bash
kubectl -n reflector get pods
kubectl -n reflector logs deploy/reflector --tail=20
```

## Anotări pe sursă

```yaml
# Pe Secret-ul sursă (în namespace-ul original)
metadata:
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "auth,car-platform"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "auth,car-platform"
```

Reflector creează automat o copie în fiecare ns listat. Updates pe sursă propagate la copies.

## Variant: regex namespace

```yaml
reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "team-.*"
```

## Verify replication

```bash
# Sursa
kubectl -n data get secret postgres-keycloak-credentials -o yaml | grep reflector

# Destinație (după ~30s)
kubectl -n auth get secret postgres-keycloak-credentials
# anotare reflector.v1.k8s.emberstack.com/reflects: data/postgres-keycloak-credentials
```

## Capcane

- Reflected secret are **anotări** ce-l identifică ca copy → NU îl modifica direct, fix doar sursa
- Schimbarea anotării `reflection-allowed-namespaces` → reflector șterge copies din ns excluse
- Dacă sursa e ștearsă → copies sunt șterse (cu `reflection-auto-enabled: true`)
