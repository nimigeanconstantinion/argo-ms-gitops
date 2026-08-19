# Code review — `argo-ms-gitops`

**Runda 4**, la commit `4d9ee84` („commit app-kong", 2026-08-19 20:24) + log-ul de pornire al pod-ului `data-service` din cluster. Înlocuiește runda 3 (`01f151c`).

Scop: de ce `data-service` nu funcționează. **Cauza s-a mutat din GitOps în imaginea aplicației.**

---

## Ce s-a rezolvat

**B3 ✅ — Kong are Application.** `argo-apps/app-kong.yaml`, wave 4, ns `business`, cu exact cele 4 surse necesare. `diff` contra originalului din `ms-gitops`: singurele diferențe sunt cele intenționate — 3× `repoURL` actualizat și 3× path-ul mutat pe `business/app-microservices/`. Fără scăpări.

**M2 ✅ — rezolvat odată cu B3.** `kong/ingress` are acum sursa lui separată de tip directory (a patra din `app-kong.yaml`), deci Ingress-urile chiar se aplică. Asta era observația din rundele 2-3.

**B1 + B2 + B5 ✅ DOVEDITE ÎN CLUSTER.** Log-ul pod-ului e verificarea pe care o ceream la pasul 1 din runda 3, și trece:

```
HikariPool-1 - Added connection com.mysql.cj.jdbc.ConnectionImpl@426913c4
HikariPool-1 - Start completed.
Database version: 8.4.8
```

Într-o singură linie asta confirmă tot lanțul de infrastructură: chart-ul `api-ms` a randat un Deployment → pod-ul a pornit → SealedSecret-ul `data-service-db` s-a decriptat → Reflector l-a copiat în ns `business` → `secretEnv` l-a injectat → `mysql-init-job` chiar crease userul `dataapp` și baza `micro_db` → MOCO răspunde. Nimic din ce am semnalat în rundele 1-3 nu mai blochează.

---

## 🔴 Critice

### B6 — NOU: aplicația crapă la pornire pe un bug de JVM, nu de configurare

`constantin-data-api/Dockerfile:1` — **fix-ul e în repo-ul aplicației, nu în ăsta.**

```
FROM openjdk:17.0.1-slim
```

Log-ul, după ce baza s-a conectat cu succes:

```
Error creating bean with name 'processorMetrics' ...
Caused by: java.lang.NullPointerException:
  Cannot invoke "jdk.internal.platform.CgroupInfo.getMountPoint()" because "anyController" is null
    at java.base/jdk.internal.platform.cgroupv2.CgroupV2Subsystem.getInstance(CgroupV2Subsystem.java:81)
    at java.base/jdk.internal.platform.CgroupSubsystemFactory.create(...)
    ...
    at io.micrometer.core.instrument.binder.system.ProcessorMetrics.<init>(ProcessorMetrics.java:85)
```

**Mecanismul, de citit de jos în sus:** actuator-ul înregistrează binderul Micrometer `ProcessorMetrics`; acesta cere `OperatingSystemMXBean`; JDK-ul, ca să raporteze corect CPU-ul *din container*, întreabă `jdk.internal.platform.Metrics` cine e cgroup-ul curent; `CgroupSubsystemFactory` detectează corect că nodul e pe **cgroup v2**, dar lista de controllere pe care o construiește din `/proc/self/mountinfo` + `/proc/self/cgroup` iese **goală**; `CgroupV2Subsystem.getInstance` dereferențiază acel `anyController` fără să verifice null → NPE în `java.base`, adică sub aplicație. Bean-ul pică, contextul Spring se anulează, procesul moare.

Trei lucruri de reținut din asta:

1. **Nu e vina codului tău și nu e o eroare de config.** Stack trace-ul intră în `java.base/jdk.internal.*` — nimic din `application.yaml` nu-l poate influența.
2. **Depinde de nod, nu de imagine.** Aceeași imagine pornește pe o gazdă cu alt layout de cgroup și crapă pe asta. De-aia „mergea înainte" nu e un contraargument — e exact semnătura acestui tip de bug. Explică și de ce n-ai văzut-o până acum.
3. **De ce tocmai `openjdk:17.0.1-slim`:** `17.0.1` e din octombrie 2021, iar imaginea oficială `openjdk` de pe Docker Hub e **depreciată și înghețată** — nu mai primește build-uri. Deci ai fixat runtime-ul pe un JVM care n-a apucat fix-urile ulterioare de detecție cgroup v2. Un tag `17` fără patch, dintr-o imagine întreținută, ar fi luat corecția singur.

**Fix (o singură variantă): copiază Dockerfile-ul de la importer-service.** Nu inventa nimic — pattern-ul corect există deja la tine în ecosistem, la `constantin-importer-api/Dockerfile`:

```dockerfile
FROM eclipse-temurin:17-jdk AS build
WORKDIR /app
COPY mvnw .
COPY .mvn .mvn
COPY pom.xml .
RUN sed -i 's/\r$//' mvnw && chmod +x mvnw
RUN ./mvnw dependency:go-offline -B
COPY src src
RUN ./mvnw package -DskipTests

FROM eclipse-temurin:17-jre
WORKDIR /app
EXPOSE 8081
COPY --from=build /app/target/data-service-0.0.1-SNAPSHOT.jar app.jar
ENTRYPOINT ["java","-jar","/app/app.jar"]
```

**Atenție la două lucruri când îl adaptezi:**

- **Fără sufixul `-alpine`.** `eclipse-temurin:*-alpine` e publicat doar pentru `linux/amd64`, iar CI-ul tău cere `linux/amd64,linux/arm64` → `buildx` pică cu `no match for platform in manifest` înainte de build. Ai pierdut 3 rulări pe capcana asta la importer.
- **Portul e 8081**, nu 8082, iar numele jar-ului e `data-service-0.0.1-SNAPSHOT.jar`.

Bonus, gratuit, din multi-stage: azi imaginea de producție conține JDK complet, Maven, `.m2` și tot `src/` — jar-ul e servit din `/app/target/`, adică din directorul de build. Cu varianta de mai sus rămâne doar JRE + un jar.

### B4 — oauth2-proxy lipsește complet (nerezolvat)

`kong/ingress/data-service-gateway.yaml:9-10` și `importer-service-gateway.yaml:9-10`

Ambele Ingress-uri cer `auth-url: http://oauth2-proxy.business.svc.cluster.local:4180/oauth2/auth`, dar nici manifestele (`business/rsk/oauth2-proxy/` în `ms-gitops`), nici Application-ul nu au fost aduse.

Acum că Kong e pe drum, ăsta rămâne **singurul lucru din GitOps** între tine și un URL funcțional. `auth_request` spre un upstream care nu rezolvă DNS → nginx întoarce **500, nu 401** — pe toate rutele, inclusiv `/actuator/health`.

---

## 🟡 Importante

### M6 — NOU: validarea Jakarta e absentă, deci adnotările de validare nu fac nimic

Log: `Failed to set up a Bean Validation provider: jakarta.validation.NoProviderFoundException: Unable to create a Configuration, because no Jakarta Bean Validation provider could be found.`

Verificat în `constantin-data-api/pom.xml`: există `spring-boot-starter-actuator`, dar **nu** `spring-boot-starter-validation`. Fără provider (Hibernate Validator), orice `@Valid`, `@NotNull`, `@Size` din DTO-uri și entități e ignorat în tăcere — cererile invalide trec mai departe.

E logat la nivel **INFO**, nu WARN. Ăsta e tiparul periculos: codul *arată* validat la citire, dar nu validează nimic la rulare, iar singurul semnal e o linie de INFO printre 30 la pornire. Fix: `spring-boot-starter-validation` în `pom.xml`.

### M4 — numele secretului cerut de CR-ul Mongo nu există (nerezolvat)

`infra/databases/mongodb.yaml:23` cere `mongodb-demo-password`; SealedSecret-ul produce `mongo-demo-password` (`mongodb-demo-secret-sealed.yaml:5,17`) — lipsește `db`. Bug moștenit din `ms-gitops`, deci Mongo n-a mers niciodată; l-ai activat acum. Nu blochează sync-ul (lipsa unui Secret nu e eroare de dry-run), dar lasă un Application permanent nesănătos. Fix: aliniază numele în `mongodb.yaml`, un singur fișier.

### M5 — `.gitignore` a pierdut protecția pentru cache-ul Helm (nerezolvat)

`.gitignore:20` → `# charts/`. A deblocat corect `business/charts/`, dar regula proteja **cache-ul de dependențe Helm**. Convenția din `ms-gitops` și car-platform: `charts/` + `!business/charts/` + `!business/charts/**`, în ordinea asta.

### M1 — `kong.yml` rutează spre un serviciu care nu există (nerezolvat)

`kong/declarative/kong.yml:8-11,22-28` — upstream + rută pentru `importer-service`, care nu e în repo-ul nou. Acum că Kong chiar se instalează, ruta devine vizibilă: `importer-service.icode.mywire.org` va da 503. Fie aduci serviciul, fie scoți ruta.

### M7 — NOU: Kong dbless nu reîncarcă `kong.yml` la modificare

`kong/declarative/kustomization.yaml:11-12` → `disableNameSuffixHash: true`

ConfigMap-ul `kong-declarative` are nume stabil, iar Kong dbless citește configul **doar la pornire**. Deci o schimbare de rută în `kong.yml` se sincronizează în ArgoCD (`Synced`, verde), dar nu ajunge în proces — rute vechi, zero semnal de eroare. La prima instalare nu se vede; te lovește la a doua modificare.

E aceeași problemă pe care ai rezolvat-o manual în `ms-gitops` cu `rollout restart deployment kong`. Forma durabilă, neaplicată nici acolo: `podAnnotations: { kong-config-rev: "N" }` în `kong/values.yaml`, incrementat la fiecare schimbare de rută → ArgoCD face rollout automat.

## 🟢 Cleanups

### C5 — NOU: dialect Hibernate specificat inutil

Log: `HHH90000025: MySQLDialect does not need to be specified explicitly using 'hibernate.dialect' (remove the property setting and it will be selected by default)`. Scoate proprietatea din `application-argo.yaml` — Hibernate 6 o deduce din conexiune.

### C3 — numele chart-ului nu e numele folderului (nerezolvat)

`business/charts/api-ms/Chart.yaml:2` → `name: microservice`, folderul e `api-ms`. Inofensiv în ArgoCD, dar `helm lint` îl semnalează. Dacă redenumirea e intenționată, du-o până la capăt.

### C4 — SealedSecret resuscitat (nerezolvat)

`infra/databases/secrets/mysql-secret-sealed.yaml` produce `mysql-app`, neconsumat de nimic (`grep -rn "mysql-app"` → doar fișierul). E secretul static retras deliberat în `ms-gitops` când a apărut `data-service-db`. Dead weight care arată exact ca acreditarea reală de MySQL.

---

## Before / After (doar în document, nu aplicat în cod)

### B6 — imaginea data-service

| Acum | Cum ar trebui |
|---|---|
| `constantin-data-api/Dockerfile:1` → `FROM openjdk:17.0.1-slim`, single-stage, jar rulat din `/app/target/`, JVM înghețat pe 17.0.1 → NPE în `CgroupV2Subsystem` la pornire | multi-stage `eclipse-temurin:17-jdk` (build) → `eclipse-temurin:17-jre` (runtime), jar copiat ca `/app/app.jar`, `EXPOSE 8081`. **Fără `-alpine`** (doar amd64 → `buildx` pică pe multiarch) |

### M6 — validarea

| Acum | Cum ar trebui |
|---|---|
| `pom.xml` are `spring-boot-starter-actuator`, dar nu are provider de validare → `@Valid`/`@NotNull` ignorate tăcut | adăugat `spring-boot-starter-validation` |

### B4 — oauth2-proxy

| Acum | Cum ar trebui |
|---|---|
| Ingress-urile cer `auth-url` spre `oauth2-proxy.business.svc:4180`; nici manifestele, nici Application-ul nu există | copiat `business/rsk/oauth2-proxy/{deployment,service,ingress,sealed-secret}.yaml` → `business/app-microservices/oauth2-proxy/` + `argo-apps/app-oauth2-proxy.yaml` (wave 4, `directory.recurse: true`, ns `business`). **Sealed-secret-ul trebuie re-sigilat**, ca celelalte |

### M7 — reload Kong

| Acum | Cum ar trebui |
|---|---|
| `kong-declarative` cu nume stabil → Kong nu recitește `kong.yml`, ArgoCD raportează `Synced` pe o config care nu e în proces | `podAnnotations: { kong-config-rev: "1" }` în `kong/values.yaml`, incrementat la fiecare schimbare de rută |

---

## Ce urmează

1. **B6** — imaginea. Până nu pornește procesul, restul e teoretic. Reține că fix-ul e în `constantin-data-api`, iar noul SHA trebuie să ajungă în `business/app-microservices/data-service/values.yaml:5` (azi `tag: 92ff0cf`) — prin `cd-bump` dacă pipeline-ul e portat pe repo-ul nou, altfel manual.
2. **B4** — oauth2-proxy. Cu Kong pus și pod-ul viu, ăsta e ultimul obstacol până la `https://data-service.icode.mywire.org`.
3. **M6 + C5** — în același commit cu B6, sunt în același repo.
4. **M4 + M5 + M7 + C4** — igienă GitOps, un singur commit.

Sync-wave-urile (mongodb-operator 0, databases 2, kong 4, data-service 5) sunt corecte.

**Observație de metodă.** În trei runde diagnosticul s-a mutat de fiecare dată cu un nivel mai jos: path inexistent (repo-server) → sync abandonat la dry-run (ArgoCD) → secret injectat, proces care crapă (JVM). Fiecare fix a fost corect și fiecare a scos la iveală următorul strat. Ăsta e mersul normal — semnul că merge bine nu e „a dispărut eroarea", ci „eroarea s-a mutat mai adânc".

---

## Q&A

1. Log-ul arată `HikariPool-1 - Start completed` **înainte** de crash. Ce anume dovedește linia asta despre B1, B2 și B5 — și de ce e o verificare mai puternică decât „Application-ul e Synced în ArgoCD"?

2. Stack trace-ul trece prin `io.micrometer...ProcessorMetrics` și ajunge în `java.base/jdk.internal.platform`. Dacă ai scoate `spring-boot-starter-actuator` din `pom.xml`, aplicația ar porni — de ce ar fi asta o reparație greșită?

3. `kong-declarative` are `disableNameSuffixHash: true`, deci nume stabil. Ce câștigi din numele stabil și ce pierzi (M7)? Ce s-ar întâmpla dacă l-ai scoate pur și simplu?

---

Stop aici. Spune „next" dacă vrei să duc B6 + M6 + C5 într-un `CODE_REVIEW.md` separat în `constantin-data-api` (unde e și fix-ul), sau review pe `importer-service` / Keycloak din repo-ul nou.
