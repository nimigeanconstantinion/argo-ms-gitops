# oauth2-proxy — poarta de auth (network gate) inainte de Kong

Stil car-platform, adaptat: **fara Crossplane**. Clientul `oauth2-proxy` e definit confidential in
`business/rsk/keycloak/realm-rsk.yaml` **fara secret in fisier** — Keycloak il genereaza. oauth2-proxy
citeste acel secret + un cookie-secret dintr-un `SealedSecret` numit `oauth2-proxy-keycloak` (ns `business`).

Acest secret **nu e comis** de review (sigilarea e legata de cheia cluster-ului tau). Il faci o singura data, la bootstrap.

## Flux

```
Browser -> https://data-service.icode.mywire.org
   nginx Ingress (data-service-gateway)  --auth-url-->  oauth2-proxy (POARTA 1: login + grup /admins)
   -> kong-proxy -> data-service /swagger-ui  (POARTA 2: client data-service-swagger, PKCE)
```

## Bootstrap (o singura data)

### 1. Re-importa realmul (KeycloakRealmImport e create-only!)
Clientul `oauth2-proxy` + grupul `/admins` sunt noi. Daca realmul `rsk` exista deja, importul nu se aplica singur:

```bash
kubectl -n auth delete keycloakrealmimport rsk-realm   # ArgoCD il recreeaza din git la sync
```

### 2. Ia client-secret-ul generat de Keycloak
Admin console `https://auth.icode.mywire.org` -> realm `rsk` -> Clients -> `oauth2-proxy` -> Credentials -> Client secret.
Sau prin kcadm:

```bash
CID=$(kcadm.sh get clients -r rsk -q clientId=oauth2-proxy --fields id --format csv --noquotes | tail -1)
kcadm.sh get clients/$CID/client-secret -r rsk --fields value
```

### 3. Genereaza cookie-secret
```bash
openssl rand -base64 32
```

### 4. Sigileaza si comite
```bash
kubectl create secret generic oauth2-proxy-keycloak \
  --namespace business \
  --from-literal=client-secret='<CLIENT_SECRET_DIN_PAS_2>' \
  --from-literal=cookie-secret='<COOKIE_SECRET_DIN_PAS_3>' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets --format yaml \
  > business/rsk/oauth2-proxy/sealed-secret.yaml

git add business/rsk/oauth2-proxy/sealed-secret.yaml && git commit -m "feat(auth): sealed secret oauth2-proxy-keycloak"
```

Dupa push + sync, pod-ul `oauth2-proxy` porneste. Pana atunci ramane in `CreateContainerConfigError` (secret lipsa) — normal.

## Verificare
```bash
kubectl -n business get deploy,pod -l app=oauth2-proxy
curl -sI https://data-service.icode.mywire.org/swagger-ui/   # 302 -> Keycloak login (nu 200 direct)
```
Login cu `admin/admin` (e in grupul `/admins`). Userul `test` NU trebuie sa treaca (nu e in /admins).
