# strimzi

Strimzi Kafka Operator — gestionează CR-uri `Kafka`, `KafkaTopic`, `KafkaUser`, `KafkaConnect`, `KafkaMirrorMaker2`.

| | |
|---|---|
| Application | `argo-apps/infra-strimzi.yaml` |
| Chart | `strimzi/strimzi-kafka-operator` 0.47.0 |
| Namespace | `messaging` |
| Wave | 0 |

## Verify

```bash
kubectl -n messaging get pods -l app.kubernetes.io/name=strimzi-kafka-operator
kubectl get crd | grep kafka.strimzi.io
```

## Lipsuri actuale

Operator instalat dar **niciun CR**:
- ❌ `Kafka` cluster (broker + KRaft, fără ZooKeeper)
- ❌ `KafkaTopic`-uri
- ❌ `KafkaUser` (dacă activezi SCRAM-SHA-512 auth)
- ❌ Kafka UI (Schema Registry + topic browser)
- ❌ ServiceMonitor pentru Prometheus

## Next: CR Kafka (KRaft, 1 broker pentru lab)

```yaml
# infra/kafka/kafka.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: messaging
  labels:
    strimzi.io/cluster: kafka
spec:
  replicas: 1
  roles: [controller, broker]
  storage:
    type: persistent-claim
    size: 10Gi
    class: local-path
    deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: kafka
  namespace: messaging
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.8.0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

Application separat `argo-apps/infra-kafka.yaml` wave 2.

## KRaft vs ZooKeeper

KRaft = Kafka Raft mode — Kafka 3.5+ gestionează metadatele intern (controller quorum), fără ZooKeeper.
- ✅ Mai simplu (un singur sistem)
- ✅ Setup mai rapid
- ✅ Future direction (ZooKeeper deprecated)

## KafkaTopic

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders-events
  namespace: messaging
  labels:
    strimzi.io/cluster: kafka
spec:
  partitions: 3
  replicas: 1
```

## Edit hint

- `replicaCount` operator: 1 (HA prod = 2 cu lock)
- `watchAnyNamespace: true` dacă vrei Kafka în alt namespace decât `messaging`
- Resources operator OK pentru lab (50m–200m CPU)
