#!/usr/bin/env bash
#
# Bootstrap script — rulează pe nodul K3s (EC2/server).
# Instalează: K3s + Helm + ArgoCD (insecure) + customizations + root Application.
#
# Usage:
#   chmod +x install.sh
#   TLS_SAN=k8s.aws.mycodepractice.com ./install.sh
#

set -eu

TLS_SAN="${TLS_SAN:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-7.7.7}"

if [ -z "$TLS_SAN" ]; then
  echo "ERROR: setează TLS_SAN (hostname public pentru K3s API)"
  echo "  Ex: TLS_SAN=k8s.aws.mycodepractice.com ./install.sh"
  exit 1
fi

echo "=== [1/5] Install K3s ==="
if command -v k3s >/dev/null 2>&1; then
  echo "K3s deja instalat, skip"
else
  curl -sfL https://get.k3s.io | sh -s - \
    --tls-san="$TLS_SAN" \
    --write-kubeconfig-mode=644 \
    --disable=traefik
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes

echo "=== [2/5] Install Helm ==="
if command -v helm >/dev/null 2>&1; then
  echo "Helm deja instalat, skip"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "=== [3/5] Install ArgoCD ==="
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd -n argocd --version "$ARGOCD_VERSION" \
  --set configs.params."server\.insecure"=true

kubectl -n argocd rollout status deployment argocd-server --timeout=180s

echo "=== [4/5] Apply customizations (tracking + ignoreDifferences + Grafana health) ==="
PATCH_FILE=$(mktemp -t argocd-patch-XXXXXX.yaml)
cat > "$PATCH_FILE" <<'EOF'
data:
  application.resourceTrackingMethod: annotation
  resource.customizations.ignoreDifferences.apps_Deployment: |
    jsonPointers:
      - /status/terminatingReplicas
  resource.customizations.ignoreDifferences.apps_StatefulSet: |
    jsonPointers:
      - /status/terminatingReplicas
  resource.customizations.health.grafana.integreatly.org_Grafana: |
    hs = {}
    if obj.status ~= nil then
      if obj.status.stage == "complete" and obj.status.stageStatus == "success" then
        hs.status = "Healthy"
        hs.message = obj.status.stage
        return hs
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for Grafana to be ready"
    return hs
EOF
kubectl patch configmap argocd-cm -n argocd --patch-file "$PATCH_FILE"
rm -f "$PATCH_FILE"

STS=$(kubectl get statefulset -n argocd -o name | grep application-controller | head -1)
kubectl rollout restart "$STS" -n argocd
kubectl rollout status "$STS" -n argocd --timeout=120s

echo "=== [5/5] Done ==="
echo ""
echo "Next steps:"
echo "  1. Editează bootstrap/root.yaml — pune URL-ul repo-ului GitOps"
echo "  2. Conectează repo în ArgoCD UI (Settings → Repositories) sau via Secret"
echo "  3. kubectl apply -f bootstrap/root.yaml"
echo ""
echo "Admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
