# Code review — `argo-ms-gitops`

**Runda 5**, la commit `e3e0374` („fix cookie secret", 2026-08-25 16:40). Acoperă cele 7 commit-uri de la `f81bec7` încoace. Înlocuiește runda 4.

Scop: închiderea lanțului GitOps (oauth2-proxy) + prima trecere peste stratul de **alertare**, care e zonă nouă, nereviewuită până acum.

**Titlul rundei:** lanțul e complet — `data-service` e accesibil din browser prin Kong, cu poarta de auth în față. Dar poarta apără o ușă a cărei cheie e publicată în același repo.

---

## Ce s-a rezolvat

**B4 ✅ — oauth2-proxy e în GitOps, complet.** `argo-apps/app-oauth2-proxy.yaml` (wave 4, ns `business`, `directory.recurse: true`) + cele 4 manifeste în `business/app-microservices/oauth2-proxy/`. `diff -ru` contra originalului din `ms-gitops`: **zero diferențe** pe deployment/service/ingress, iar în Application doar cele două intenționate (`repoURL`, `path`). Ăsta era ultimul blocant din GitOps.

**Sealed-secret-ul chiar l-ai re-sigilat** — ciphertext diferit pe ambele chei, plus `type: Opaque` adăugat în template, care lipsea în original. Exact ce ceream la B4 în runda 4, dus până la capăt.

**B6 ✅ — imaginea e reparată și DOVEDITĂ.** `constantin-data-api` a ajuns pe `eclipse-temurin:17-jdk`, run CI `32338755810` verde (7m44s, multi-arch), iar `business/app-microservices/data-service/values.yaml:5` e pe `tag: 4c98961` = exact SHA-ul acelui build. NPE-ul din `CgroupV2Subsystem` nu mai poate apărea: temurin `17` fără patch fix e imagine întreținută, cu corecția inclusă.

**Drumul până acolo merită păstrat — trei încercări, trei lecții diferite:**

| Commit | Bază | Ce s-a întâmplat |
|---|---|---|
| `c77041f` | `eclipse-temurin:17-jre` | CI pică. JRE n-are compilator → `./mvnw package` nu are cu ce lucra. Într-un Dockerfile single-stage, baza trebuie să fie JDK. |
| `ec55cfc` | `eclipse-temurin:17-jdk-alpine` | CI pică. Exact capcana de la importer: `-alpine` e publicat doar pentru `linux/amd64`, iar CI-ul cere `amd64,arm64` → `buildx` refuză înainte de build. |
| `4c98961` | `eclipse-temurin:17-jdk` | Verde. |

Cele două eșecuri sunt de fapt cele două jumătăți ale fix-ului corect: JDK **pentru build**, imagine fără `-alpine` **pentru multiarch**. Le-ai avut pe amândouă, separat. Vezi C8 pentru ce a rămas pe drum.

**✅ Ceva ce ai închis singur, fără să-ți cer — și e tiparul rundelor 1-4.** În `ms-gitops`, `infra/kube-prometheus-stack/alertmanager-config.yaml` era **fișier orfan**: Application-ul nu-l referea, iar configul chiar aplicat era o copie ascunsă în `sealed-secrets/` (prinsă accidental de `include: "*.yaml"`). În repo-ul nou ai adăugat surse dedicate pentru el (`infra-kube-prometheus-stack.yaml:33-43`). Asta e fix lecția de la B3 (Kong) și M2 (`kong/ingress`), aplicată din proprie inițiativă pe alt strat: **un fișier în repo nu e un fișier în cluster; între ele trebuie să existe o sursă care să-l ia.**

---

## 🔴 Critice

### B8 — NOU: poarta e reală, cheia e publicată. Repo-ul e PUBLIC.

Verificat azi: `gh repo view nimigeanconstantinion/argo-ms-gitops` → `"visibility": "PUBLIC"`.

`business/app-microservices/keycloak/realm/rsk.yaml:168-181`:

```yaml
  - username: admin
    credentials:
      - type: password
        value: admin
        temporary: false
    realmRoles:
      - "ADMIN"
    groups:
      - "/admins"
```

Și `deployment.yaml:31` → `--allowed-group=/admins`.

**Pune cele două împreună.** Tocmai ai instalat oauth2-proxy ca network gate în fața lui Kong, care lasă să treacă doar membrii `/admins`. Singurul membru al lui `/admins` e userul `admin`, cu parola `admin`, scrisă în clar într-un repo public, împreună cu URL-ul exact al realm-ului (`https://auth.icode.mywire.org/realms/rsk`) și cu hostname-urile protejate. Oricine citește repo-ul se autentifică și trece de poartă. Nu e o slăbiciune teoretică: e credențialul care deschide exact ce ai construit ca să închizi.

În aceeași categorie, în același fișier public:

| Linie | Ce e expus | Consecință |
|---|---|---|
| `rsk.yaml:85` | client secret `oauth2-proxy` în clar | SealedSecret-ul `oauth2-proxy-keycloak` nu mai protejează nimic — valoarea lui e scrisă lângă el, necriptată |
| `rsk.yaml:133` | `secret: "my-secret-keycloak"` pentru `registration-service` | service account cu `serviceAccountsEnabled: true` și `fullScopeAllowed: true` |
| `rsk.yaml:151-166` | user `test` / parolă `test` | fără `/admins`, deci nu trece de poartă azi; devine problemă în clipa în care lărgești `--allowed-group` |

**Mecanismul de reținut, pentru că e contraintuitiv:** SealedSecret rezolvă o singură problemă — *cum ajunge un secret în cluster prin git*. Nu rezolvă *de unde vine valoarea*. Aici valoarea vine din `rsk.yaml`, care e text simplu, aplicat de `keycloak-config-cli` la fiecare sync. Ai criptat copia și ai publicat originalul. Un secret e „scurs" din momentul în care a fost comis, nu din momentul în care îl observă cineva — deci ștergerea fișierului nu repară nimic, el rămâne în istoricul git.

**Fix, o singură variantă, în ordinea asta:**

1. **Rotești tot ce e mai sus** — client secret oauth2-proxy, secretul lui `registration-service`, parola `admin`. Ce e comis e compromis.
2. **Scoți userii din realm.** Convenția pe care o folosim în `car-platform`: **zero useri declarativi**. Realm-ul din git descrie *clienți, scope-uri, mappere, grupuri* — structura. Userii și apartenența la `/admins` se creează manual în Keycloak UI, o dată. Motivul e exact ăsta: structura poate fi publică, identitățile nu.
3. **Secretele de client trec prin substituție**, nu prin literal: `IMPORT_VAR_SUBSTITUTION_ENABLED=true` pe Job-ul `keycloak-config-cli` + `secret: "$(env:OAUTH2_PROXY_CLIENT_SECRET)"` în `rsk.yaml`, cu variabila injectată în Job din SealedSecret-ul care există deja.
4. Cât timp pasul 1 nu e făcut: **repo privat**. E o comandă, nu un refactor.

> Notă de verificare, separată de securitate: comentariul de la `rsk.yaml:78` spune „aceeasi valoare e in SealedSecret". Tu ai re-sigilat SealedSecret-ul în `985ae26`/`e3e0374`. Dacă ai sigilat **altă** valoare decât cea de la `:85`, `keycloak-config-cli` scrie la fiecare sync valoarea din `rsk.yaml` peste ce știe Keycloak, iar oauth2-proxy va da `invalid_client` la login — eroare care se citește greșit, ca „Keycloak e picat". Verifică o singură dată: `kubectl -n business get secret oauth2-proxy-keycloak -o jsonpath='{.data.client-secret}' | base64 -d` trebuie să dea exact șirul de la `rsk.yaml:85`.

### B7 — NOU: construiești alertare peste Prometheus-ul configurat exact cu limita care l-a omorât

`infra/kube-prometheus-stack/values.yaml:18-24`

```yaml
    resources:
      requests:
        memory: 512Mi
      limits:
        memory: 1Gi
```

Pe 6 august, în `ms-gitops`, exact aceste două valori au fost mărite la `1Gi` / `3Gi`, commit `0d42511`, după un incident: `prometheus-...-0` intra în `exitCode 137` (OOMKilled) la fiecare pornire, murind constant în `"Replaying WAL"` la `segment=1832 maxSegment=2970`. Bucla se auto-întreținea — nu putea porni ca să-și facă curat, pentru că nu putea porni.

În repo-ul nou valorile sunt din nou cele dinainte de fix. Nu e o schimbare pe care ai făcut-o: e **un fix pierdut la copiere**, al treilea din aceeași familie (C4 a readus un secret retras deliberat, M5 a pierdut o regulă de `.gitignore`). Tiparul e constant și merită numit: **copiezi starea, nu istoricul.** Fișierul copiat arată la fel de valid ca oricare altul — nimic din el nu spune „valoarea asta e rezultatul unui incident". De-asta, la fișierele venite din repo-ul vechi, `git log --oneline -- <fișier>` în `ms-gitops` e verificarea care lipsește; are 5 secunde.

**De ce e 🔴 tocmai în runda asta, și nu în alta:** alertarea pe care o construiești acum trăiește în Prometheus. Dacă el moare, nu doar că pierzi metrici — pierzi *și* alertele care ar fi trebuit să-ți spună că e ceva în neregulă. E exact bucla din 6 august: erori → loguri → disc → evacuări → Prometheus jos → nicio alertă → se repetă. Un sistem de alertare care tace când clusterul suferă e mai rău decât niciun sistem de alertare, pentru că tăcerea lui se citește ca „e bine".

---

## 🟡 Importante

### M8 — NOU: alerta de test rămasă în repo trimite pe Slack la fiecare oră, la infinit

`infra/kube-prometheus-stack/slack-test-alert.yaml:12-19`

```yaml
- alert: SlackTestAlert
  expr: vector(1)
  for: 30s
  labels:
    severity: critical
```

`vector(1)` întoarce mereu `1`, deci condiția e mereu adevărată. Alerta intră în `firing` la 30 de secunde după deploy și **nu iese niciodată**. Are `severity: critical` → prinde a doua rută din `alertmanager-config.yaml:24-30` → `repeatInterval: 1h`. Adică un mesaj pe Slack la fiecare oră, pentru totdeauna. `sendResolved: true` nu se declanșează niciodată, pentru că nu există „resolved" pentru `vector(1)`.

Ca test de conectivitate e corect gândit — e cel mai simplu mod de a dovedi lanțul PrometheusRule → Alertmanager → webhook. Problema e că testul a rămas în producție. Iar costul lui nu e zgomotul, ci ce face zgomotul cu tine: după două zile, notificarea de la stack-ul de monitoring devine ceva ce închizi fără să citești. Când vine alerta reală de temperatură, aterizează în același canal, cu același aspect, în același reflex.

**Fix:** șterge fișierul după ce ai confirmat că mesajul a ajuns. Dacă vrei o alertă permanentă de tip „lanțul e viu" (watchdog), ea are altă formă: `severity: none`, rutată către un receiver separat, sau — mai bine — folosită invers, ca *dead man's switch*, unde un sistem extern se alarmează când **încetează** să sosească. Chart-ul îți dă deja una gata făcută: regula `Watchdog` din `kube-prometheus-stack`.

### M9 — NOU: alerta de temperatură spune trei lucruri diferite

`slack-test-alert.yaml:20-28` + `alertmanager-config.yaml:16-22`

| Unde | Ce spune |
|---|---|
| comentariu `:20` | „Alerta pentru temperatura de peste **75°C**" |
| `expr:22` | `max(node_hwmon_temp_celsius) by (instance) > **85**` |
| `labels:25` | `severity: **warning**` |
| `description:28` | „a depășit **pragul critic**" |

Trei surse de adevăr, trei valori. Peste asta, o inversiune de urgență: ruta dedicată (`alertmanager-config.yaml:17-22`) prinde alerta **după `alertname`**, deci înainte de ruta pe `severity`, și îi dă `repeatInterval: 10m`. Rezultat: o alertă etichetată `warning` te sună de 6 ori mai des decât una `critical`. În Alertmanager rutele se evaluează **în ordine, prima potrivire câștigă** (nu e `continue: true`), deci a doua rută nici nu e consultată pentru ea.

Alege un singur adevăr: dacă 85°C chiar e prag critic, `severity: critical` și scoți ruta specială — cea generică îi dă deja `groupWait: 0s`. Dacă e prag de avertizare, coboară `repeatInterval` la ceva mai blând și corectează textul.

**De verificat înainte de toate, o dată:** că metrica există. `node_hwmon_temp_celsius` vine din colectorul `hwmon` al node-exporter-ului și **depinde de hardware** — pe multe VM-uri nu apare deloc. O alertă pe o metrică inexistentă nu dă eroare: pur și simplu nu se evaluează niciodată, tăcut. În Prometheus: query `node_hwmon_temp_celsius` → dacă e „Empty query result", alerta e decorativă.

### M10 — NOU: `ms-gitops` încă primește commit-uri automate, iar Application-urile au aceleași nume

Run-ul CI `32338755810` (2026-08-20) s-a terminat cu job-ul `cd-bump`, care a scris `tag: 4c98961` în **`business/rsk/data-service/values.yaml` din `ms-gitops`** — pentru că `.github/workflows/ci.yml:50` din `constantin-data-api` are încă `repository: nimigeanconstantinion/ms-gitops`. De-asta a trebuit să bumpezi manual în `a58f9d9`: pipeline-ul a mers unde a fost trimis, doar că nu mai e acolo repo-ul care contează.

Riscul real nu e commit-ul irosit, ci ăsta: **cele două repo-uri declară Application-uri cu aceleași nume** (`data-service`, `kong`, `oauth2-proxy`, `kube-prometheus-stack`…) în același namespace `argocd`. Numele unui Application e unic în namespace. Dacă root app-ul vechi mai e înregistrat în cluster, cele două root-uri se calcă reciproc: fiecare reconciliere rescrie `spec.source` al aceluiași obiect, iar ArgoCD sincronizează alternativ din repo-ul vechi și din cel nou. Simptomul e neplăcut de diagnosticat — un app care „revine singur" la o configurație pe care ai schimbat-o, fără nimeni care să o schimbe.

**Verifică o dată, e o comandă:**

```bash
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,REPO:.spec.source.repoURL,REPOS:.spec.sources[*].repoURL
```

Orice linie cu `ms-gitops` în repo-ul nou = ping-pong. Apoi: ori ștergi root app-ul vechi, ori muți `cd-bump` pe `argo-ms-gitops` (path-ul e `business/app-microservices/data-service/values.yaml`, nu `business/rsk/...`) — de făcut oricum, în toate cele 3 servicii.

### M4 · M5 · M7 — nerezolvate din rundele 3-4

Neschimbate, verificate azi: `mongodb.yaml:23` cere `mongodb-demo-password`, secretul produce `mongo-demo-password` (M4) · `.gitignore:20` are `# charts/` comentat integral, deci cache-ul Helm nu mai e protejat (M5) · `kong/declarative/kustomization.yaml:11-12` `disableNameSuffixHash: true`, deci Kong nu recitește `kong.yml` (M7). Detaliile sunt în runda 4; toate trei încap într-un singur commit de igienă.

### M6 — validarea Jakarta, în `constantin-data-api` (nerezolvat)

`pom.xml` are `spring-boot-starter-actuator`, nu are `spring-boot-starter-validation` → `@Valid`/`@NotNull` sunt no-op. A supraviețuit celor 3 commit-uri de Dockerfile.

---

## 🟢 Cleanups

### C6 — NOU: două surse pentru același director

`argo-apps/infra-kube-prometheus-stack.yaml:33-43` — două surse cu `repoURL`, `targetRevision` și `path` identice, diferite doar prin `include`. Se scriu ca una singură:

```yaml
    - repoURL: https://github.com/nimigeanconstantinion/argo-ms-gitops.git
      targetRevision: master
      path: infra/kube-prometheus-stack
      directory:
        include: "{alertmanager-config.yaml,slack-test-alert.yaml}"
```

Sintaxa cu acolade e glob standard, aceeași pe care o acceptă `exclude`. **Verifică totuși în ArgoCD, o dată, că app-ul are în arbore și `AlertmanagerConfig/default`, și `PrometheusRule/slack-test-alert`** — dacă una dintre ele lipsește, sursele duplicate au fost deduplicate și ai un fișier orfan exact de tipul celui de la B3, doar că bine ascuns.

### C7 — NOU: documentația n-a migrat

Lipsesc din repo-ul nou, față de `ms-gitops`: tot `docs/migrare/` (plan, backlog, cei 3 pași `00`-`03`, `SOLUTIONS.md`), `docs/diagrame/` (`.drawio` + PDF-urile de arhitectură), `NEXT_STEPS.md`, `argo-apps/README.md`, `infra/README.md`. `GETTING_STARTED.md` e nou și acoperă altceva.

E singura categorie de fișiere pe care „copiere fără triere" a **sărit-o** complet — și e exact categoria unde stă *de ce*-ul deciziilor: de ce `keycloak-config-cli` în loc de `KeycloakRealmImport`, de ce wave 2 pentru databases, de ce 3Gi la Prometheus (vezi B7). Manifestele spun *ce*; fără `docs/`, *de ce*-ul rămâne doar în capul tău.

### C8 — NOU: `AS build` fără al doilea stage

`constantin-data-api/Dockerfile:1` → `FROM eclipse-temurin:17-jdk AS build`. Nu există niciun `COPY --from=build`, deci eticheta nu face nimic, iar `ENTRYPOINT` rulează jar-ul direct din `/app/target/`. E jumătatea de sus a Dockerfile-ului pe care ți l-am dat în runda 4, oprită la mijloc.

Funcționează — B6 e închis, NPE-ul a dispărut. Ce pierzi e ce dă multi-stage-ul gratis: imaginea de producție conține JDK complet, Maven, tot cache-ul `.m2` și tot `src/`. Numele `build` rămas acolo e util ca semn de carte: ți-a rămas de scris stage-ul al doilea (`FROM eclipse-temurin:17-jre` + `COPY --from=build`).

### C3 · C4 — nerezolvate din runda 3

`business/charts/api-ms/Chart.yaml:2` are încă `name: microservice` ≠ folderul `api-ms` (C3) · `infra/databases/secrets/mysql-secret-sealed.yaml` produce `mysql-app`, neconsumat de nimic (C4).

---

## Before / After (doar în document, nu aplicat în cod)

### B8 — userii din realm

| Acum | Cum ar trebui |
|---|---|
| `rsk.yaml:168-181` — user `admin`, parolă `admin`, membru `/admins`, comis în repo **public**; `:85` client secret în clar; `:133` `my-secret-keycloak` | fără bloc `users:` în git — grupul `admins` rămâne declarativ, membrii se adaugă manual în Keycloak UI; secretele de client prin `$(env:...)` + `IMPORT_VAR_SUBSTITUTION_ENABLED=true` pe Job. **Toate trei valorile rotite**, indiferent de fix — sunt deja în istoricul git |

### B7 — memoria Prometheus

| Acum | Cum ar trebui |
|---|---|
| `values.yaml:20,24` → `requests.memory: 512Mi`, `limits.memory: 1Gi` — valorile de dinainte de incidentul din 6 august | `requests.memory: 1Gi`, `limits.memory: 3Gi`, ca în `ms-gitops` după `0d42511`. Dacă nodul n-are RAM pentru 3Gi, atunci scazi `retention`/`retentionSize`, nu limita |

### M8 — alerta de test

| Acum | Cum ar trebui |
|---|---|
| `slack-test-alert.yaml:12-19` — `expr: vector(1)`, `severity: critical`, firing permanent, 1 mesaj/oră la infinit | fișierul șters după confirmarea primului mesaj; pentru „lanțul e viu" folosești `Watchdog`-ul care vine deja cu chart-ul, rutat separat |

### M9 — alerta de temperatură

| Acum | Cum ar trebui |
|---|---|
| comentariu 75°C, `expr > 85`, `severity: warning`, text „prag critic", rută dedicată cu `repeatInterval: 10m` — mai insistentă decât `critical` | un singur prag în toate cele patru locuri; dacă e critic → `severity: critical` și ștergi ruta pe `alertname`, cea generică îi dă deja `groupWait: 0s` |

---

## Ce urmează

1. **B8** — rotit cele 3 credențiale + scos blocul `users:`. Până atunci, repo privat. Restul poate aștepta; asta nu.
2. **B7** — o linie în `values.yaml`, în același commit cu M8 + M9 (toate trei sunt în `infra/kube-prometheus-stack/`).
3. **M10** — o comandă de verificare, apoi `cd-bump` mutat pe repo-ul nou în toate cele 3 servicii.
4. **M4 + M5 + M7 + C3 + C4 + C6** — un singur commit de igienă GitOps.
5. **M6 + C8** — în `constantin-data-api`, împreună.

**Observație de metodă, continuarea celei din runda 4.** Patru runde la rând, diagnosticul a coborât un nivel: path inexistent → sync abandonat la dry-run → proces care crapă. Runda asta rupe tiparul, și e un semn bun: nu mai am ce diagnostica în lanțul de livrare — el funcționează. Ce a apărut în loc sunt probleme de **operare**: un secret publicat, o limită de memorie pierdută la copiere, o alertă care strigă degeaba. Astea nu se manifestă ca erori, ci ca obișnuință — nu apar în niciun log, nu fac niciun Application roșu, și de-asta se descoperă abia când e prea târziu ca să mai conteze că le-ai fi putut vedea.

---

## Q&A

1. `oauth2-proxy` lasă să treacă doar membrii `/admins`, iar `rsk.yaml` e singurul loc unde grupul și membrii lui sunt definiți. Dacă mâine faci repo-ul privat și schimbi parola userului `admin` **doar în Keycloak UI**, ce se întâmplă la următorul sync ArgoCD și de ce? (Răspunsul e în ce înseamnă „idempotent" pentru `keycloak-config-cli`.)

2. Un fișier copiat din `ms-gitops` arată identic cu unul scris de la zero — nimic din conținutul lui nu spune că o valoare e rezultatul unui incident (B7). Ce comandă rulezi, în repo-ul vechi, ca să afli asta înainte de a copia, și ce anume cauți în output?

3. `SlackTestAlert` are `expr: vector(1)`, deci e mereu în `firing`. Regula `Watchdog` din kube-prometheus-stack are exact aceeași expresie. De ce una e zgomot și cealaltă e utilă — ce diferă, dacă nu expresia?

---

Stop aici. Spune „next" dacă vrei să duc M6 + C8 într-un `CODE_REVIEW.md` separat în `constantin-data-api`, sau review pe `importer-service` / Keycloak din repo-ul nou (încă neîncepute).
