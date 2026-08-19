# Code review — `argo-ms-gitops`, commit `9a71d7d` („commit kong si data-service")

Scop: de ce Application-ul `data-service` nu sincronizează în ArgoCD.

Context: commit-ul mută în repo-ul nou `argo-ms-gitops` o parte din setup-ul care mergea în repo-ul vechi `ms-gitops` (local: `projects-elevi/constantin-gitops/`). Fișierele copiate sunt byte-identice cu originalele — nu ele sunt problema. Problema e **ce n-a fost copiat**: chart-ul pe care îl referă Application-ul și 3 Applications de care depinde lanțul.

---

## 🔴 Critice

### B1 — Application-ul indică un path care nu există în repo

`argo-apps/app-data-service.yaml:16`

```yaml
path: business/charts/microservice
```

În `argo-ms-gitops` nu există `business/charts/`. Verificare:

```
git ls-tree -r --name-only HEAD business/
business/app-microservices/data-service/values.yaml
business/app-microservices/keycloak/...
business/app-microservices/kong/...
```

Chart-ul (`Chart.yaml`, `templates/deployment.yaml`, `templates/service.yaml`, `templates/ingress.yaml`, `values.yaml`) există doar în repo-ul vechi, la `business/charts/microservice/`.

Rezultat în ArgoCD: `ComparisonError` la nivel de Application, cu `rpc error: ... app path does not exist`. Nu se generează niciun manifest, deci nu ajunge niciodată să încerce un Deployment.

**Mecanismul:** într-un Application multi-source, sursa cu `path:` + `helm:` e chart-ul, iar sursa cu `ref: values` e doar un repo montat sub `$values` pentru fișiere de valori. `valueFiles: [$values/...]` s-a rezolvat corect (fișierul chiar există), dar valorile nu au ce randa. Un chart lipsă e eroare de *repo-server*, înainte de orice comparație cu clusterul — de asta Application-ul e roșu fără să existe vreun pod.

---

### B2 — `infra/databases/` nu e referit de nicio Application

`argo-apps/` (lipsește `infra-databases.yaml`) vs `infra/databases/`

Directorul există în repo și conține:

```
infra/databases/mysql.yaml              MySQLCluster (MOCO)
infra/databases/mysql-init-job.yaml     creeaza userul dataapp + baza micro_db
infra/databases/secrets/data-service-db-sealed.yaml
```

Dar nicio Application nu-l aplică (`grep -l databases argo-apps/` → gol). În repo-ul vechi exista `argo-apps/infra-databases.yaml`, wave 2, cu `directory.recurse: true`.

Consecință directă, chiar după ce rezolvi B1: `business/app-microservices/data-service/values.yaml:27-29` cere

```yaml
secretEnv:
  MYSQL_USERNAME: { secret: data-service-db, key: username }
  MYSQL_PASSWORD: { secret: data-service-db, key: password }
```

Secret-ul `data-service-db` nu ajunge niciodată în cluster → pod-ul rămâne în `CreateContainerConfigError: secret "data-service-db" not found`. Și `MYSQL_URL` (`values.yaml:20`) arată spre `moco-mysql-primary.data.svc:3306/micro_db` — și `MySQLCluster`-ul, și baza `micro_db` vin tot din directorul neaplicat.

Atenție la `recurse: true`: fără el ArgoCD citește doar nivelul de sus și ratează `secrets/*.yaml`. Comentariul din repo-ul vechi spunea exact asta.

---

### B3 — Kong nu are Application; Ingress-urile trimit spre un Service inexistent

`business/app-microservices/kong/` (orfan) și `argo-apps/` (lipsește `app-kong.yaml`)

Ai comis `kong/values.yaml`, `kong/declarative/{kong.yml,kustomization.yaml}` și `kong/ingress/*.yaml`, dar nimic nu le consumă. Root app-ul scanează doar `argo-apps/` (`bootstrap/root.yaml:15-17`, `recurse: false`), deci fișierele din `business/` sunt inerte până când un Application le referă.

Rezultat: `business/app-microservices/kong/ingress/data-service-gateway.yaml:26-30`

```yaml
backend:
  service:
    name: kong-proxy
    port:
      number: 80
```

`kong-proxy` nu există în namespace-ul `business` → nginx returnează 503 pe `data-service.icode.mywire.org`. Iar Ingress-ul nici măcar nu e aplicat, fiindcă și el e orfan (vezi M2).

În repo-ul vechi, `app-kong.yaml` avea 4 surse: chart-ul de la `https://charts.konghq.com` (3.4.0), `ref: values`, `path: .../kong/ingress` și `path: .../kong/declarative`.

---

### B4 — oauth2-proxy lipsește complet, dar ambele Ingress-uri îl cer

`business/app-microservices/kong/ingress/data-service-gateway.yaml:9-10` și `importer-service-gateway.yaml:9-10`

```yaml
nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.business.svc.cluster.local:4180/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "https://$host/oauth2/start?rd=$escaped_request_uri"
```

În `argo-ms-gitops` nu există nici manifestele oauth2-proxy, nici `app-oauth2-proxy.yaml`. În repo-ul vechi erau la `business/rsk/oauth2-proxy/` (deployment, service, ingress, sealed-secret) plus Application cu `recurse: true`.

**Mecanismul:** `auth-url` face nginx să emită un sub-request (`auth_request`) la fiecare cerere, înainte de a o trimite la backend. Dacă acel upstream nu rezolvă DNS, nginx nu dă „acces interzis", ci **500** — pe toate rutele, inclusiv `/actuator/health` și pagina Swagger. E o eroare care se citește ca „aplicația e picată", deși aplicația n-a fost atinsă.

---

## 🟡 Importante

### M1 — `kong.yml` rutează spre `importer-service`, care nu există în acest repo

`business/app-microservices/kong/declarative/kong.yml:8-11` și `:22-28`

```yaml
- name: importer-service-upstream
  targets:
    - target: importer-service.business.svc:8082
```

Nu există `business/app-microservices/importer-service/values.yaml` și nici `app-importer-service.yaml`. Kong dbless pornește oricum (nu validează DNS-ul target-urilor la boot), dar ruta `importer-service.icode.mywire.org` va da 503. Alege conștient: fie porți și importer-service acum, fie scoți ruta din `kong.yml` până atunci — să nu rămână o rută moartă care arată ca un bug de rețea.

### M2 — `kong/ingress/` n-are `kustomization.yaml`; trebuie sursă separată de tip „directory"

`business/app-microservices/kong/ingress/`

`declarative/` are `kustomization.yaml` (generează ConfigMap-ul `kong-declarative`), dar `ingress/` are doar două manifeste simple. În repo-ul vechi mergea pentru că `app-kong.yaml` le lua ca **a treia sursă separată**, plain directory. Dacă reconstruiești app-kong cu o singură sursă pe `business/app-microservices/kong/`, Ingress-urile nu se aplică — ArgoCD alege un singur tip de sursă per `path`.

### M3 — SealedSecret-ul e legat de cheia controller-ului, nu de repo

`infra/databases/secrets/data-service-db-sealed.yaml:5-9`

SealedSecret-ul e criptat pentru cheia privată a controller-ului `sealed-secrets` din clusterul unde a fost sigilat, **și** e scoped pe `namespace: data` + `name: data-service-db`. Dacă `argo-ms-gitops` ajunge pe un cluster nou (sau ai reinstalat sealed-secrets fără să restaurezi cheia), decriptarea eșuează cu `no key could decrypt secret` — iar simptomul e identic cu B2 (`secret not found`). Verifică întâi în evenimentele SealedSecret-ului, nu în pod.

---

## 🟢 Cleanups

### C1 — `repoURL` la copiere

Fișierele din repo-ul vechi au `repoURL: .../ms-gitops.git`. În `app-data-service.yaml` ai actualizat corect ambele apariții la `argo-ms-gitops.git`. Când aduci `app-kong.yaml` (3 apariții), `app-oauth2-proxy.yaml` (1) și `infra-databases.yaml` (1), actualizează-le pe toate. Un `repoURL` greșit nu dă eroare de sintaxă — dă un Application care sincronizează fericit din repo-ul vechi și te induce în eroare la următoarea modificare.

### C2 — numele resurselor se leagă corect

`app-data-service.yaml:18` are `releaseName: data-service`, iar `templates/deployment.yaml` din chart folosește `{{ .Release.Name }}` pentru Deployment și Service. Deci Service-ul iese `data-service` în ns `business`, ceea ce se potrivește exact cu `target: data-service.business.svc:8081` din `kong.yml:6` și cu `containerPort: 8081` / `service.port: 8081` din values. Partea asta e coerentă — n-o atinge.

---

## Before / After (doar în document, nu aplicat în cod)

### B1 — chart-ul lipsă

| Acum | Cum ar trebui |
|---|---|
| `argo-apps/app-data-service.yaml:16` → `path: business/charts/microservice`, iar `business/charts/` nu există în repo | copiat din `ms-gitops` întreg directorul: `business/charts/microservice/{Chart.yaml,values.yaml,templates/{deployment,service,ingress}.yaml}` — path-ul din Application rămâne neschimbat |

### B2 — Application pentru `infra/databases`

| Acum | Cum ar trebui |
|---|---|
| `infra/databases/` există în repo, dar `grep -l databases argo-apps/` → gol | fișier nou `argo-apps/infra-databases.yaml`: |

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: databases
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/nimigeanconstantinion/argo-ms-gitops.git
    targetRevision: master
    path: infra/databases
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: data
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### B3 — Application pentru Kong

| Acum | Cum ar trebui |
|---|---|
| `business/app-microservices/kong/**` orfan, `kong-proxy` inexistent | fișier nou `argo-apps/app-kong.yaml`, wave 4, cu 4 surse: |

```yaml
  sources:
    - repoURL: https://charts.konghq.com
      chart: kong
      targetRevision: 3.4.0
      helm:
        releaseName: kong
        valueFiles:
          - $values/business/app-microservices/kong/values.yaml
    - repoURL: https://github.com/nimigeanconstantinion/argo-ms-gitops.git
      targetRevision: master
      ref: values
    - repoURL: https://github.com/nimigeanconstantinion/argo-ms-gitops.git
      targetRevision: master
      path: business/app-microservices/kong/ingress
    - repoURL: https://github.com/nimigeanconstantinion/argo-ms-gitops.git
      targetRevision: master
      path: business/app-microservices/kong/declarative
```

### B4 — oauth2-proxy

| Acum | Cum ar trebui |
|---|---|
| Ingress-urile cer `auth-url` spre `oauth2-proxy.business.svc:4180`; nici manifestele, nici Application-ul nu există în repo | copiat `business/rsk/oauth2-proxy/{deployment,service,ingress,sealed-secret}.yaml` → `business/app-microservices/oauth2-proxy/` + `argo-apps/app-oauth2-proxy.yaml` (wave 4, `directory.recurse: true`, ns `business`) |

---

## Ordinea de reparat

Contează, pentru că fiecare pas schimbă simptomul:

1. **B1** — Application-ul iese din `ComparisonError` și începe să genereze manifeste.
2. **B2** — pod-ul iese din `CreateContainerConfigError` și pornește.
3. **B3 + B4** — abia acum are sens să testezi în browser; până aici orice 500/503 e zgomot, nu diagnostic.

Sync-wave-urile existente (databases 2, kong/oauth2-proxy 4, data-service 5) sunt deja corecte pentru lanțul ăsta — nu le schimba.

---

## Q&A

1. `app-data-service.yaml` are două surse din **același** repo, una cu `path:` și una cu `ref: values`. De ce e nevoie de a doua, când fișierul de valori e în același repo cu Application-ul? Ce s-ar întâmpla dacă ștergi sursa cu `ref: values` și pui `valueFiles: [business/app-microservices/data-service/values.yaml]`?

2. `infra-databases.yaml` din repo-ul vechi avea `directory.recurse: true`, cu un comentariu explicit. Dacă îl adaugi **fără** `recurse`, ce anume ajunge în cluster și ce nu — și în ce stare rămâne pod-ul `data-service`?

3. Ingress-ul are `auth-url` spre oauth2-proxy. Dacă oauth2-proxy lipsește, nginx întoarce 500, nu 401/403. De ce 500 și nu un cod de „neautorizat"? Ce concluzie greșită te-ar putea duce codul ăsta să tragi despre `data-service`?

---

Stop aici. Spune „next" dacă vrei să continui cu review pe `importer-service` sau pe partea de Keycloak/realm din repo-ul nou.
