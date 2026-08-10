# ArgoCD Bootstrap Starter

Starter **minimal** pentru a porni un cluster K3s/K8s cu GitOps prin ArgoCD.

Conține DOAR:
- App of Apps (root)
- NGINX Ingress (necesar pentru orice expunere HTTP/HTTPS)
- Sealed Secrets (necesar pentru a stoca credențiale criptate în git)
- cert-manager (pentru certificate TLS valide via Let's Encrypt)

**Restul componentelor** (cert-manager, ECK + ELK, Prometheus, Grafana, etc.) le adaugi incremental, urmând pattern-ul din `docs/adding-operators.md`.

## De ce minim?

- Pornești curat, cu o stivă mică pe care o înțelegi complet
- Înveți pattern-ul de adăugare operator pas cu pas (nu primești un stack ready-made pe care nu-l înțelegi)
- Decizi tu ce componente îți trebuie (poate nu vrei ELK, poate vrei alt tool de monitoring)

Pentru un stack complet (cu observability + cert-manager + Grafana Operator deja configurate), vezi `argocd-platform-starter/` — același folder părinte.

## Structură

```
argocd-bootstrap-starter/
├── bootstrap/
│   └── root.yaml                 ← App of Apps (aplicat manual o singură dată)
├── argo-apps/                     ← scanat de root, NU conține root.yaml
│   ├── infra-nginx-ingress.yaml
│   ├── infra-sealed-secrets.yaml
│   └── infra-cert-manager.yaml
├── infra/
│   ├── nginx-ingress/values.yaml
│   ├── sealed-secrets/values.yaml
│   └── cert-manager/values.yaml
├── apps/                          ← gol; aici adaugi Application-uri pentru aplicații
├── scripts/
│   ├── cleanup-cluster.sh
│   └── full-reset.sh
└── docs/
    ├── README.md                  ← Setup pas cu pas
    └── adding-operators.md        ← Cum adaugi un operator nou (RECIPE)
```

**De ce root.yaml stă în `bootstrap/`, nu în `argo-apps/`?**
Root scanează folderul `argo-apps/`. Dacă root.yaml ar fi acolo, root s-ar "vedea pe sine" → diff infinit + risc ca root să se șteargă singur cu `prune: true`. Mutându-l în `bootstrap/`, scannerul nu îl mai vede.

## Workflow tipic

1. **Bootstrap minimal** — folosești acest starter (root + nginx + sealed-secrets) → ArgoCD funcțional cu 3 Applications verzi
2. **Adaugă incremental** componente (cert-manager, ECK, Prometheus, etc.) folosind recipe-ul din `docs/adding-operators.md`
3. **Adaugi aplicația ta** ca al N-lea Application în `argo-apps/`

Fiecare pas e un commit + push + ArgoCD sync. **Niciodată** nu apply manual cu `kubectl apply` resurse care ar trebui gestionate de ArgoCD.

## Quick start

Vezi `docs/README.md`.

## Placeholder-e de înlocuit

- `__GITHUB_USERNAME__` → username-ul tău GitHub
- `__GITHUB_REPO__` → numele repo-ului GitOps
- Branch în `targetRevision`: `main` sau `master` (verifică ce ai pe GitHub)
