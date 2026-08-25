#!/usr/bin/env bash
set -euo pipefail

NS_PROXY="business"
NS_AUTH="auth"
SECRET_NAME="oauth2-proxy-keycloak"
DEPLOY="oauth2-proxy"
TARGET="business/app-microservices/oauth2-proxy/sealed-secret.yaml"
CLIENT_SECRET='BtJSmntRRePW105y3kM1f3V9kxc/pN6AA8hIw/N8wjA='

confirma() {
  local raspuns
  read -r -p "$1 [y/N] " raspuns
  [[ "$raspuns" == "y" || "$raspuns" == "Y" ]]
}

echo "=============================================================="
echo " Resigilare client-secret oauth2-proxy"
echo " Cauza: token exchange failed: unauthorized_client"
echo "        (secretul din SealedSecret != secretul din Keycloak)"
echo "=============================================================="
echo

echo "--- 0. Verificari preliminare ---"

for unealta in kubectl kubeseal git; do
  command -v "$unealta" >/dev/null 2>&1 || { echo "ERROR: $unealta not found in PATH"; exit 1; }
done

RADACINA="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a git repository."
  exit 1
}
cd "$RADACINA"

[[ -f "$TARGET" ]] || {
  echo "ERROR: $TARGET not found in $RADACINA."
  echo "Scriptul trebuie rulat din repo-ul argo-ms-gitops."
  exit 1
}

CONTEXT="$(kubectl config current-context)"
echo "Context kubectl : $CONTEXT"
echo "Namespace proxy : $NS_PROXY"
echo "Fisier tinta    : $TARGET"
echo
confirma "Contextul de mai sus e clusterul lui Constantin (server2)?" || {
  echo "Oprit. Schimba contextul cu: kubectl config use-context <nume>"
  exit 1
}
echo

echo "--- 1. A ajuns realm-ul in Keycloak? ---"
echo "Daca jobul de mai jos a picat, valoarea din rsk.yaml NU e in Keycloak,"
echo "iar resigilarea ei nu repara nimic — ia atunci secretul din Keycloak UI."
echo
kubectl -n "$NS_AUTH" logs job/keycloak-config-cli --tail=15 2>/dev/null || \
  echo "(jobul keycloak-config-cli nu mai exista — hook-ul e sters dupa rulare, normal)"
echo
confirma "Continui?" || { echo "Oprit."; exit 0; }
echo

echo "--- 2. Recuperez cookie-secret din Secret-ul decriptat ---"
COOKIE="$(kubectl -n "$NS_PROXY" get secret "$SECRET_NAME" -o jsonpath='{.data.cookie-secret}' | base64 -d)"

case "${#COOKIE}" in
  16|24|32) echo "OK: cookie-secret are ${#COOKIE} bytes." ;;
  0)  echo "ERROR: cookie-secret is empty — wrong key name or missing secret."; exit 1 ;;
  *)  echo "ERROR: cookie-secret has ${#COOKIE} bytes, expected 16, 24 or 32."; exit 1 ;;
esac
echo

echo "--- 3. Sigilez in fisier temporar ---"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

kubectl -n "$NS_PROXY" create secret generic "$SECRET_NAME" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > "$TMP"

grep -q "namespace: $NS_PROXY" "$TMP"   || { echo "ERROR: sealed output has wrong namespace."; exit 1; }
grep -q "name: $SECRET_NAME" "$TMP"     || { echo "ERROR: sealed output has wrong name."; exit 1; }
grep -q "client-secret:" "$TMP"         || { echo "ERROR: client-secret missing from output."; exit 1; }
grep -q "cookie-secret:" "$TMP"         || { echo "ERROR: cookie-secret missing from output."; exit 1; }
echo "OK: name, namespace si ambele chei sunt in output."

cp "$TMP" "$TARGET"
echo "Scris: $TARGET"
echo
git --no-pager diff --stat -- "$TARGET"
echo

echo "--- 4. Commit + push ---"
if confirma "Comit si trimit modificarea?"; then
  git add "$TARGET"
  git commit -m "fix: resigilat client-secret oauth2-proxy (unauthorized_client la redeem)"
  git push
  echo "Trimis. Asteapta ca ArgoCD sa sincronizeze app-ul oauth2-proxy."
else
  echo "Sarit. Fisierul e modificat local, comite-l manual cand vrei."
fi
echo

echo "--- 5. Restart pod (OBLIGATORIU) ---"
echo "Variabilele din secretKeyRef se citesc o singura data, la pornirea pod-ului."
echo "Fara restart: secret corect peste tot, ArgoCD verde, si tot 500 in browser."
echo
if confirma "Repornesc deployment/$DEPLOY acum? (doar dupa ce ArgoCD a sincronizat)"; then
  kubectl -n "$NS_PROXY" rollout restart "deployment/$DEPLOY"
  kubectl -n "$NS_PROXY" rollout status "deployment/$DEPLOY" --timeout=120s
  echo
  echo "--- 6. Log dupa restart ---"
  kubectl -n "$NS_PROXY" logs "deployment/$DEPLOY" --tail=20
else
  echo "Sarit. Cand esti gata:"
  echo "  kubectl -n $NS_PROXY rollout restart deployment/$DEPLOY"
fi

echo
echo "=============================================================="
echo " Verificare finala, in browser:"
echo "   https://data-service.icode.mywire.org/swagger-ui/index.html"
echo
echo " Daca tot da 500, in log-ul proxy-ului conteaza continuarea liniei"
echo " 'Error redeeming code during OAuth2 callback:'"
echo "   unauthorized_client       -> secretul tot nu coincide (ia-l din Keycloak UI)"
echo "   failed to get claim email -> alta cauza, scope-uri pe client"
echo "=============================================================="
