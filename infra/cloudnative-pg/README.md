# cloudnative-pg

CloudNativePG Operator — gestionează CR-uri `Cluster` (PostgreSQL), `Backup`, `ScheduledBackup`, `Pooler`.

| | |
|---|---|
| Application | `argo-apps/infra-cloudnative-pg.yaml` |
| Chart | `cloudnative-pg/cloudnative-pg` 0.22.1 |
| Namespace | `data` |
| Wave | 0 |
| Release | `cnpg` |

## Verify

```bash
kubectl -n data get pods -l app.kubernetes.io/name=cloudnative-pg
kubectl get crd | grep cnpg
```

## Lipsuri actuale

Operator instalat dar **niciun CR**:
- ❌ `Cluster` (Postgres pentru Keycloak)
- ❌ `Cluster` (Postgres pentru aplicațiile business)
- ❌ `ScheduledBackup` (CronJob backup pe S3)
- ❌ ServiceMonitor pentru Prometheus

## Next: Cluster Postgres pentru Keycloak

```yaml
# infra/postgres-keycloak/cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-keycloak
  namespace: data
spec:
  instances: 1                    # HA prod = 3
  primaryUpdateStrategy: unsupervised

  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
      secret:
        name: postgres-keycloak-credentials    # creează SealedSecret

  storage:
    size: 5Gi
    storageClass: local-path

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 1,    memory: 1Gi }
```

Application separat `argo-apps/infra-postgres-keycloak.yaml` wave 2.

## SealedSecret pentru credențiale

```bash
# Plain (local)
cat > /tmp/pg-keycloak-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-keycloak-credentials
  namespace: data
type: kubernetes.io/basic-auth
stringData:
  username: keycloak
  password: "ParolaSigura123!"
EOF

# Sigilează
kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets-controller \
         --format yaml \
         < /tmp/pg-keycloak-raw.yaml \
         > infra/postgres-keycloak/credentials-sealed.yaml
rm /tmp/pg-keycloak-raw.yaml
```

## Acces la DB

```bash
# Service intern (din pod-uri în cluster)
postgres-keycloak-rw.data.svc.cluster.local:5432   # primary R/W
postgres-keycloak-ro.data.svc.cluster.local:5432   # read-only replicas

# Port-forward pentru psql local
kubectl -n data port-forward svc/postgres-keycloak-rw 5432:5432

# Connect (parola din secret)
PGPASSWORD=$(kubectl -n data get secret postgres-keycloak-credentials -o jsonpath='{.data.password}' | base64 -d) \
  psql -h localhost -U keycloak -d keycloak
```

## Mirror secret în alt namespace (via Reflector)

Keycloak rulează în `ns: auth`, dar secret-ul Postgres e în `ns: data`. Adaugă anotări pe secret pentru replicare automată cu Reflector:

```yaml
metadata:
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "auth"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
```

## Backup pe S3 (next, prod)

```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://my-bucket/backups
      s3Credentials:
        accessKeyId:
          name: s3-creds
          key: access-key-id
        secretAccessKey:
          name: s3-creds
          key: secret-access-key
    retentionPolicy: "30d"
```
