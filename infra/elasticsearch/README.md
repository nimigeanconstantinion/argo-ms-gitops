# elasticsearch

CR `Elasticsearch` — single-node cluster pentru logs/metrics.

| | |
|---|---|
| Application | `argo-apps/infra-elasticsearch.yaml` |
| Tip | raw manifests (single-source path) |
| Wave | 2 (după eck-operator wave 0) |
| Namespace | `logging` |
| Versiune | 8.15.3 |

## Config curent

- 1 nod cu toate rolurile (master + data + ingest + ml + transform)
- 10Gi storage (`storageClassName: local-path` — K3s default)
- JVM: -Xms1g -Xmx1g (heap)
- Pod resources: 500m–2 CPU, 2Gi memory
- TLS: self-signed (enabled)
- `node.store.allow_mmap: false` — K3s nu permite mmap fără ulimit, OK pentru lab

## Verify

```bash
kubectl -n logging get elasticsearch
kubectl -n logging get pods -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch
```

Status: `HEALTH=green` + `PHASE=Ready` în ~2 min.

## Acces

```bash
# Parola user elastic
kubectl -n logging get secret elasticsearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d

# Port-forward pentru testare
kubectl -n logging port-forward svc/elasticsearch-es-http 9200:9200

# Test
curl -k -u "elastic:<parola>" https://localhost:9200/_cluster/health
```

## Edit hint

- Pentru prod: `count: 3` cu `node.roles` separate (master / data / coord)
- Pentru memory pressure: crește `ES_JAVA_OPTS: -Xms2g -Xmx2g` + pod limits 4Gi
- Snapshot repository: adaugă `s3` plugin via `initContainers` + `keystore`

## Lipsuri actuale

- ❌ ServiceMonitor pentru Prometheus
- ❌ Ingress public (acces ES doar prin port-forward)

## Backup

```bash
# Snapshot manual API
curl -k -u "elastic:<parola>" -X PUT \
  https://localhost:9200/_snapshot/my-backup/snap-$(date +%s) \
  -H "Content-Type: application/json" \
  -d '{"indices": "*", "include_global_state": true}'
```
