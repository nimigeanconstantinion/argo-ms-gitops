# Folder gol — aplicații

Aici pui **valorile/manifestele specifice aplicațiilor tale** (separat de `infra/` care conține componente cluster-wide).

Structură tipică:

```
apps/
└── <my-platform>/
    ├── values-prod.yaml          ← override values per cluster pentru chart-ul tău
    ├── sealed-secrets/
    │   ├── mysql-auth.yaml
    │   ├── keycloak-auth.yaml
    │   └── ...
    └── dashboards/                ← GrafanaDashboard CR-uri specifice aplicației (opțional)
        └── ...
```

Application-ul ArgoCD care leagă chart-ul aplicației de aceste values îl pui în `argo-apps/app-<numele>.yaml`.

Vezi `docs/adding-operators.md` pentru pattern-ul de Application.
