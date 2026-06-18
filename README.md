# 🏠 charthouse

> Helm chart repository — infrastructure as code, shipped with GitHub Actions.

Charts are automatically packaged and published to GitHub Pages via [`chart-releaser`](https://github.com/helm/chart-releaser).

---

## Add the repository

```bash
helm repo add charthouse https://willbrid.github.io/charthouse
helm repo update
```

---

## Available charts

| Chart | Description | Version |
|-------|-------------|---------|
| `grafana` | A Helm chart for installing grafana in Kubernetes | `0.1.0` |

> **Note:** Update this table as you add new charts.

---

## Install a chart

```bash
# Install with default values
helm install my-release charthouse/<chart-name>

# Install with custom values
helm install my-release charthouse/<chart-name> \
  --namespace my-namespace \
  --create-namespace \
  --values my-values.yaml

# Preview what will be deployed (dry-run)
helm install my-release charthouse/<chart-name> --dry-run
```

---

## Upgrade & uninstall

```bash
# Upgrade an existing release
helm upgrade my-release charthouse/<chart-name> --values my-values.yaml

# Uninstall
helm uninstall my-release
```

---

## Repository structure

```
charthouse/
├── charts/
│   ├── application1/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── templates/
│   │   └── ci/               # Test values for CI
│   └── application2/
│       └── ...
└── .github/
    └── workflows/
        ├── lint-test.yml     # Triggered on pull_request
        └── release.yml       # Triggered on push to main
```

---

## CI/CD

| Workflow | Trigger | Action |
|----------|---------|--------|
| `lint-test` | Pull Request | Lint + install charts on a [kind](https://kind.sigs.k8s.io/) cluster |
| `release` | Push to `main` | Package & publish charts to GitHub Pages |

A chart is only released when its `version` in `Chart.yaml` is bumped.

---

## Versioning

All charts follow [Semantic Versioning](https://semver.org/) — `x.y.z` where `x`, `y` and `z` are integers from 0 to 9.

```
  1 . 4 . 2
  │   │   └── PATCH — bug fix, no functional change
  │   └────── MINOR — new feature, backwards compatible
  └────────── MAJOR — breaking change
```

| Level | When to bump | Example |
|-------|-------------|---------|
| `MAJOR` (`x`) | Breaking change — values renamed/removed, incompatible behavior | `1.4.2` → `2.0.0` |
| `MINOR` (`y`) | New feature or new optional value, fully backwards compatible | `1.4.2` → `1.5.0` |
| `PATCH` (`z`) | Bug fix, doc update, typo — no API change | `1.4.2` → `1.4.3` |

> **Rule:** when `MAJOR` is bumped, reset `MINOR` and `PATCH` to `0`.  
> When `MINOR` is bumped, reset `PATCH` to `0`.

Start new charts at `0.1.0`. Move to `1.0.0` once the chart is considered stable and production-ready.

---

## Contributing

1. Create a branch and make your changes inside `charts/<chart-name>/`
2. Bump the `version` field in the relevant `Chart.yaml`
3. Open a pull request — lint and install tests run automatically
4. Once merged to `main`, the chart is published automatically

---

## License

This project is licensed under the MIT License - see the [LICENSE](https://github.com/willbrid/charthouse/blob/main/LICENSE) file for more details.
