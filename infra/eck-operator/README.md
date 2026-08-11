# eck-operator

Elastic Cloud on Kubernetes — operator pentru CR-uri Elasticsearch / Kibana / Logstash / Beats / ApmServer.

| | |
|---|---|
| Application | `argo-apps/infra-eck.yaml` |
| Chart | `elastic/eck-operator` v3.4.0 |
| Namespace | `logging` |

## CRD-uri principale

- `Elasticsearch` (vezi `infra/elasticsearch/`)
- `Kibana` (vezi `infra/kibana/`)
- `Beat` — Filebeat DaemonSet (vezi `infra/filebeat/`)
- `Logstash` — pipeline ingest (nefolosit — log-urile merg direct la ES via Filebeat)
- `ApmServer` — APM tracking (nefolosit)

## Verify

```bash
kubectl -n logging get pods
kubectl get crd | grep elastic.co
```

Operator pod: `elastic-operator-0`.

## Edit hint

`values.yaml` — minim acum. Custom common:
- `installCRDs: true` (default)
- `replicaCount: 1` (HA pentru prod = 3)
- `manageNamespace: false` dacă vrei să gestionezi ns separat

## Stack curent

- `eck-operator` (wave 0) → `logging`
- `elasticsearch` (wave 2) → `logging`
- `kibana` (wave 3) + Ingress → `logging`
- `filebeat` Beat CR (wave 3) → `logging`

Toate CR-urile referă ES/Kibana cu `namespace: logging` explicit (vezi `infra/filebeat/filebeat.yaml`).
