# Getting Started

Ghid pas cu pas pentru a porni un cluster K3s cu GitOps prin ArgoCD.

## Prerequizite

- O mașină Linux (Ubuntu 22.04+ recomandat) cu acces root — local, VM, EC2, etc.
- Un domeniu (ex: `mycodepractice.com`) cu acces la DNS (Cloudflare, Route53, etc.)
- Un cont GitHub + un repo gol pentru GitOps

## Pasul 1 — Pregătește repo-ul GitOps

1. Pe GitHub: creează un repo nou, **privat** sau public (ex: `my-gitops`).
2. Clonează acest starter în repo-ul tău:
   ```bash
   git clone https://github.com/<owner>/argocd-bootstrap-starter.git my-gitops
   cd my-gitops
   rm -rf .git
   git init
   git remote add origin https://github.com/<owner>/my-gitops.git
   ```
3. Înlocuiește placeholder-ele în `argo-apps/*.yaml` și `bootstrap/root.yaml`:
   - `__GITHUB_USERNAME__` → username-ul tău
   - `__GITHUB_REPO__` → numele repo-ului
   - `targetRevision: main` sau `master` (după branch-ul tău)
4. Commit + push:
   ```bash
   git add .
   git commit -m "bootstrap from starter"
   git push -u origin main
   ```

## Pasul 2 — DNS

În provider-ul DNS (Cloudflare, etc.):

- A record `k8s.<domeniu>` → IP-ul public al serverului (gray cloud / DNS only)
- A record `*.<domeniu>` → același IP (gray cloud) — wildcard pentru subdomenii

## Pasul 3 — Rulează install.sh pe server

SSH în server, apoi:

```bash
git clone https://github.com/<owner>/my-gitops.git
cd my-gitops/bootstrap
chmod +x install.sh
TLS_SAN=k8s.<domeniu> ./install.sh
```

Script-ul instalează: **K3s + Helm + ArgoCD + customizations**.

La final afișează **admin password** — notează-l.

## Pasul 4 — Acces kubectl de pe laptop (opțional)

Pe server:
```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Pe laptop:
1. Salvează conținutul în `~/.kube/configs/<cluster-name>.yaml`
2. Înlocuiește `https://127.0.0.1:6443` cu `https://k8s.<domeniu>:6443`
3. **Redenumește** cluster + user din `default` în nume unice (altfel intră în conflict la merge)
4. Merge cu kubeconfig-ul existent

## Pasul 5 — Conectează repo în ArgoCD

Două opțiuni:

**A) UI**: port-forward la ArgoCD → `https://localhost:8080` → Settings → Repositories → Connect Repo cu HTTPS + PAT.

**B) Secret (declarativ)**:
```bash
kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-gitops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/<owner>/my-gitops.git
  username: <owner>
  password: <PAT>
EOF
```

## Pasul 6 — Aplică root Application

```bash
kubectl apply -f bootstrap/root.yaml
```

ArgoCD va sincroniza automat:
- `sealed-secrets` (în `kube-system`)
- `nginx-ingress` (în `ingress-nginx`)
- `cert-manager` (în `cert-manager`)

Verifică:
```bash
kubectl -n argocd get applications
```

Toate ar trebui să devină `Synced + Healthy` în 2-3 minute.

## Pasul 7 — ClusterIssuer pentru Let's Encrypt

După ce cert-manager e Healthy, aplică ClusterIssuer (de adăugat în repo, sub `infra/cert-manager-issuers/`):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <email>
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

## Pasul 8 — Aplicația ta cu Ingress + TLS

Adaugă annotation pe Ingress:
```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - app.<domeniu>
      secretName: app-tls
  rules:
    - host: app.<domeniu>
      ...
```

cert-manager cere certul automat, îl pune în secret, nginx-ingress îl folosește.

## Troubleshooting

- **`kubectl` connection refused**: verifică portul `6443` în SG/firewall, gray cloud în DNS
- **ArgoCD UI nu se deschide**: port-forward + `https://localhost:8080`, accept certul self-signed
- **Application stuck OutOfSync**: vezi în UI butonul `DIFF`
- **Cert nu se emite**: `kubectl describe certificate -A` pentru detalii

## Structura adăugării unui operator nou

Pattern repetitiv:
1. `argo-apps/infra-<nume>.yaml` — Application (multi-source: chart + values)
2. `infra/<nume>/values.yaml` — values custom
3. (opțional) `infra/<nume>-cr/<resurse>.yaml` + Application separată pentru CR-uri

Aceeași logică pentru Kafka (Strimzi), Postgres (CNPG), Auth (Keycloak), etc.
