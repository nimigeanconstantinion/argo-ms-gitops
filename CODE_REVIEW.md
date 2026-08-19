# Code review — `argo-ms-gitops`

**Runda 2**, la commit `230fc3e` („commit add infra-databases", 2026-08-19). Înlocuiește runda 1 (`af5cabc`, pe commit `9a71d7d`).

Scop: de ce Application-ul `data-service` nu sincronizează în ArgoCD.

Context neschimbat: repo-ul nou mută pe bucăți setup-ul din `ms-gitops`. Fișierele copiate sunt byte-identice cu originalele — problema e ce n-a fost copiat încă.

---

## Ce s-a rezolvat din runda 1

**B2 ✅ — `argo-apps/infra-databases.yaml` creat, corect.** Verificat `diff` contra originalului din `ms-gitops`: singura diferență e `repoURL`, actualizat la `argo-ms-gitops.git` (linia 15). `directory.recurse: true` păstrat (fără el s-ar fi ratat `secrets/*.yaml`), wave 2 păstrat, `ServerSideApply` păstrat. Exact ce trebuia.

**Dar nu produce încă efectul dorit** — vezi B5 mai jos. Application-ul e corect scris; conținutul directorului pe care îl aplică nu e complet.

---

## 🔴 Critice

### B5 — NOU: `databases` conține un CR fără operatorul lui → sync-ul întregului Application eșuează

`infra/databases/mongodb.yaml:5-6`

```yaml
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
```

CRD-ul `mongodbcommunity.mongodb.com` e instalat de MongoDB Community Operator. În `argo-ms-gitops` **nu există nici `argo-apps/infra-mongodb-operator.yaml`, nici `infra/mongodb-operator/`** — ambele au rămas în `ms-gitops`. Verificare: `ls infra/` nu conține `mongodb-operator`; `grep -l mongodb argo-apps/*` → gol.

Am verificat toate cele 3 CR-uri din director, nu doar unul:

| Fișier | `kind` | Operatorul lui | În repo nou? |
|---|---|---|---|
| `mysql.yaml` | `MySQLCluster` (moco.cybozu.com) | `argo-apps/infra-moco.yaml` | ✅ |
| `postgres-cluster.yaml` | `Cluster` (postgresql.cnpg.io) | `argo-apps/infra-cloudnative-pg.yaml` | ✅ |
| `mongodb.yaml` | `MongoDBCommunity` | — | ❌ |

**De ce e critic și nu doar „un pod în minus":** ArgoCD face **dry-run pe TOATE resursele fazei înainte de a aplica ceva**. O resursă cu `kind` necunoscut pică la dry-run, iar operațiunea de sync e abandonată în bloc — mesajul e `one or more synchronization tasks are not valid`. Îl mai ai o dată în istoric: exact eroarea de la migrarea CRD-urilor Strimzi.

Consecință directă: **`data-service-db` nu se aplică**, deși e în același director și e perfect valid. Deci simptomul rămâne identic cu cel din runda 1 — pod-ul în `CreateContainerConfigError: secret "data-service-db" not found` — dar cauza s-a mutat. Dacă te uiți doar la pod, pare că B2 n-a fost reparat; dovada e în `Application databases` → `SYNC FAILED`, nu în pod.

**Recomandarea (o singură variantă):** scoate Mongo din repo-ul nou, nu adăuga operatorul. Nimic din stack nu-l folosește — `grep -rl mongo` în afara lui `infra/databases/` nu întoarce nimic; data-service și importer-service merg pe MySQL. Un operator în plus înseamnă un CRD, un Deployment și un wave de întreținut pentru zero consumatori. Îl aduci din `ms-gitops` când chiar apare un serviciu care cere Mongo.

---

### B1 — NEREZOLVAT: Application-ul indică un path care nu există în repo

`argo-apps/app-data-service.yaml:16`

```yaml
path: business/charts/microservice
```

Neschimbat față de runda 1. `git ls-tree -r --name-only HEAD business/` întoarce doar `app-microservices/**` — `business/charts/` nu există. Chart-ul e la `ms-gitops` → `business/charts/microservice/` (5 fișiere: `Chart.yaml`, `values.yaml`, `templates/{deployment,service,ingress}.yaml`).

ArgoCD: `ComparisonError ... app path does not exist`, la nivel de repo-server, înainte de orice comparație cu clusterul. **Acesta rămâne blocantul #1** — până nu-l rezolvi, B5 nici măcar nu contează, pentru că nu se generează niciun Deployment care să ceară secretul.

**Atenție la `.gitignore` când îl copiezi.** În `ms-gitops` chart-ul a fost o dată invizibil pentru ArgoCD exact din motivul ăsta: regula `charts/` prindea și `business/charts/`, deci folderul nu ajungea în git deși exista pe disc. `.gitignore`-ul din repo-ul nou trebuie verificat înainte de commit — un `git status` care nu-l arată e semnalul.

---

### B3 — NEREZOLVAT: Kong nu are Application

`business/app-microservices/kong/**` (orfan) și `argo-apps/` (lipsește `app-kong.yaml`)

Neschimbat. Root app-ul scanează doar `argo-apps/` (`bootstrap/root.yaml:15-17`, `recurse: false`), deci `kong/values.yaml`, `kong/declarative/` și `kong/ingress/` sunt inerte. Ingress-ul `data-service-gateway.yaml:26-30` trimite spre Service-ul `kong-proxy`, care nu există → 503.

---

### B4 — NEREZOLVAT: oauth2-proxy lipsește complet

`kong/ingress/data-service-gateway.yaml:9-10` și `importer-service-gateway.yaml:9-10`

Neschimbat. Ambele Ingress-uri cer `auth-url: http://oauth2-proxy.business.svc.cluster.local:4180/oauth2/auth`, dar nici manifestele (`business/rsk/oauth2-proxy/` în vechi), nici Application-ul nu au fost aduse.

`auth_request` spre un upstream care nu rezolvă DNS → nginx întoarce **500, nu 401** — pe toate rutele, inclusiv `/actuator/health`. Se citește ca „aplicația e picată" deși aplicația n-a fost atinsă.

---

## 🟡 Importante (neschimbate din runda 1)

- **M1** `kong/declarative/kong.yml:8-11,22-28` — upstream + rută pentru `importer-service`, care nu există în repo-ul nou. Kong dbless pornește (nu validează DNS-ul target-urilor la boot), dar ruta dă 503. Fie aduci serviciul, fie scoți ruta — să nu rămână o rută moartă care arată ca un bug de rețea.
- **M2** `kong/ingress/` n-are `kustomization.yaml`. În `ms-gitops` mergea pentru că `app-kong.yaml` îl lua ca **sursă separată de tip directory**. Un singur `path` pe folderul `kong/` nu aplică Ingress-urile — ArgoCD alege un singur tip de sursă per path.
- **M3** SealedSecret-ul `data-service-db` e criptat pentru cheia controller-ului din clusterul unde a fost sigilat și e scoped pe `namespace: data` + `name: data-service-db`. Pe alt cluster (sau după reinstalarea sealed-secrets fără restaurarea cheii) dă `no key could decrypt secret` — simptom identic cu B5. Distincția se face în evenimentele SealedSecret-ului, nu în pod.

## 🟢 Cleanups

- **C1 ✅** `repoURL` actualizat corect în `infra-databases.yaml:15`. A rămas valabil pentru ce urmează: `app-kong.yaml` are **3** apariții, `app-oauth2-proxy.yaml` una. Un `repoURL` lăsat pe `ms-gitops` nu dă eroare — sincronizează tăcut din repo-ul vechi.
- **C2** `app-data-service.yaml:18` are `releaseName: data-service`, chart-ul folosește `{{ .Release.Name }}` pentru Deployment și Service → iese `data-service` în ns `business`, ceea ce se potrivește exact cu `target: data-service.business.svc:8081` din `kong.yml:6`. Coerent, nu atinge.

---

## Before / After (doar în document, nu aplicat în cod)

### B5 — CR orfan în `infra/databases`

| Acum | Cum ar trebui |
|---|---|
| `infra/databases/mongodb.yaml` (`kind: MongoDBCommunity`) + `infra/databases/secrets/mongodb-demo-secret-sealed.yaml`, fără operator în repo → `one or more synchronization tasks are not valid`, app-ul `databases` nu aplică NIMIC | ambele fișiere șterse din `argo-ms-gitops` (`git rm`). Nimic din stack nu le folosește. Directorul rămâne cu `mysql.yaml`, `mysql-init-job.yaml`, `postgres-cluster.yaml` + `secrets/{data-service-db,external-db-secrets,keycloak-db}-sealed.yaml` — toate cu operatorul prezent |

### B1 — chart-ul lipsă

| Acum | Cum ar trebui |
|---|---|
| `app-data-service.yaml:16` → `path: business/charts/microservice`, iar `business/charts/` nu există | copiat din `ms-gitops` întreg `business/charts/microservice/{Chart.yaml,values.yaml,templates/{deployment,service,ingress}.yaml}`; verificat cu `git status` că `.gitignore` nu-l înghite. Path-ul din Application rămâne neschimbat |

### B3 — Application pentru Kong

| Acum | Cum ar trebui |
|---|---|
| `business/app-microservices/kong/**` orfan, `kong-proxy` inexistent | fișier nou `argo-apps/app-kong.yaml`, wave 4, ns `business`, cu 4 surse: |

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
| Ingress-urile cer `auth-url` spre `oauth2-proxy.business.svc:4180`; nici manifestele, nici Application-ul nu există | copiat `business/rsk/oauth2-proxy/{deployment,service,ingress,sealed-secret}.yaml` → `business/app-microservices/oauth2-proxy/` + `argo-apps/app-oauth2-proxy.yaml` (wave 4, `directory.recurse: true`, ns `business`) |

---

## Ordinea de reparat

Actualizată față de runda 1 — B5 se inserează înaintea a ceea ce era B2:

1. **B1** — Application-ul `data-service` iese din `ComparisonError` și începe să genereze manifeste.
2. **B5** — Application-ul `databases` iese din `SYNC FAILED`, iar `data-service-db` ajunge în cluster → pod-ul pornește.
3. **B3 + B4** — abia acum are sens testul în browser; până aici orice 500/503 e zgomot, nu diagnostic.

Sync-wave-urile existente (databases 2, kong/oauth2-proxy 4, data-service 5) sunt corecte pentru lanțul ăsta — nu le schimba.

**Regulă de verificare, valabilă de la B5 încolo:** după fiecare pas, uită-te întâi la **starea Application-ului în ArgoCD**, nu la pod. B2 a fost reparat corect și simptomul din pod n-a mișcat deloc — pentru că adevărul era într-un `SYNC FAILED` la două niveluri distanță.

---

## Q&A

1. `data-service-db-sealed.yaml` e un manifest perfect valid, iar `mongodb.yaml` e în alt fișier. De ce eșecul lui Mongo îl împiedică pe primul să ajungă în cluster — ce face ArgoCD **înainte** de a aplica resursele unei faze?

2. În `ms-gitops`, `infra-mongodb-operator.yaml` avea `sync-wave: 0`, iar `infra-databases.yaml` are `sync-wave: 2`. Dacă ai alege să aduci operatorul în loc să ștergi CR-ul, de ce n-ar fi de ajuns să pui cele două Applications în același wave?

3. După ce repari B1 și B5, pod-ul `data-service` pornește. Ce te aștepți să vezi la `https://data-service.icode.mywire.org` — și care dintre B3/B4 dă 503 și care dă 500? De ce lipsa lui oauth2-proxy NU dă 401?

---

Stop aici. Spune „next" dacă vrei review pe `importer-service` sau pe partea de Keycloak/realm din repo-ul nou.
