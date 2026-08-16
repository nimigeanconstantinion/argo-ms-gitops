# kube-prometheus-stack

Stack complet observability: Prometheus + Alertmanager + kube-state-metrics + node-exporter.

| | |
|---|---|
| Application | `argo-apps/infra-kube-prometheus-stack.yaml` |
| Chart | `prometheus-community/kube-prometheus-stack` 65.5.0 |
| Namespace | `monitoring` |
| Wave | 1 |
| Grafana inclusă | ✅ EMBEDDED (Ingress: grafana.icode.mywire.org, admin via SealedSecret) |

## Componente livrate

| Componentă | Rol |
|---|---|
| Prometheus | Collect metrics (retenție 7d, 10Gi storage) |
| Alertmanager | Routing alerts (1Gi storage) |
| kube-state-metrics | Metrici K8s resources |
| prometheus-node-exporter | Metrici noduri (CPU/mem/disk/network) |
| Grafana | UI dashboards, embedded — ingress https://grafana.icode.mywire.org |
| CRDs | ServiceMonitor, PodMonitor, PrometheusRule, AlertmanagerConfig |

## Verify

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get prometheus,alertmanager
kubectl -n monitoring get servicemonitor

# Port-forward Prometheus UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/targets — verifică `UP` pe scrape targets
```

## Auto-discovery

`serviceMonitorSelectorNilUsesHelmValues: false` + `podMonitorSelectorNilUsesHelmValues: false` → Prometheus scanează `ServiceMonitor`/`PodMonitor` din **TOATE** namespace-urile.

Adaugă `ServiceMonitor` în orice namespace → Prometheus începe să scrape automat:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-svc-monitor
  namespace: car-platform
spec:
  selector:
    matchLabels: { app: my-app }
  endpoints:
    - port: metrics
      interval: 30s
```

## `ignoreDifferences` — de ce sunt

```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers: [/status]              # chart-ul re-injectează CRD status la fiecare reconcile
  - group: apps
    kind: Deployment
    jsonPointers: [/status/terminatingReplicas]   # apare doar pe k8s 1.31+
  - group: apps
    kind: StatefulSet
    jsonPointers: [/status/terminatingReplicas]
```

Fără ele, ArgoCD ar rămâne permanent `OutOfSync` pe drift cosmetic.

## Edit hint

- `retention: 7d` — crește la 15d/30d dacă ai storage
- `storageSpec.volumeClaimTemplate.resources.requests.storage: 10Gi` — minim safe; high-traffic clusters 50Gi+
- Resources Prometheus 200m–1 CPU, 512Mi–1Gi — crește dacă vezi OOMKilled

## Lipsuri actuale

- ❌ ServiceMonitor pentru aplicațiile tale (sync-service, importer-service, etc.)
- ❌ AlertmanagerConfig (routing alerts spre email/Slack/Discord)
- ❌ PrometheusRule custom (alert pe high-error-rate, pod-restarts)
- ❌ Ingress public (`prometheus.<domeniu>` + auth)

## Dashboard-uri Grafana

 Adaugă ConfigMap cu label `grafana_dashboard: "1"` în orice namespace → sidecar-ul Grafana îl încarcă automat. Dashboards comunitate utile (import via UI Grafana, ID de pe grafana.com): 315 (K8s cluster), 1860 (node exporter), 12114 (K8s deployment).
