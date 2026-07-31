# 🏠 charthouse

[![CI](https://github.com/willbrid/charthouse/actions/workflows/lint-test.yml/badge.svg?branch=main)](https://github.com/willbrid/charthouse/actions/workflows/lint-test.yml)
[![Release](https://github.com/willbrid/charthouse/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/willbrid/charthouse/actions/workflows/release.yml)

> Helm chart repository — infrastructure as code, shipped with GitHub Actions.

Charts are automatically packaged and published as OCI artifacts to [GitHub Container Registry](https://ghcr.io) via [`chart-releaser`](https://github.com/helm/chart-releaser).

---

## Available charts

| Chart | Description | Version | Published |
|-------|-------------|---------|-----------|
| `grafana` | A Helm chart for installing grafana in Kubernetes | `0.1.1` | ✅ |
| `otelcollector` | A Helm chart for installing opentelemetry collector in Kubernetes | `0.1.0` | ✅ |

> **Note:** Update this table as you add new charts.

---

## Install a chart

```bash
# Install with default values
helm install my-release oci://ghcr.io/willbrid/charts/<chart-name> --version <version>

# Install with custom values
helm install my-release oci://ghcr.io/willbrid/charts/<chart-name> \
  --version <version> \
  --namespace my-namespace \
  --create-namespace \
  --values my-values.yaml

# Preview what will be deployed (dry-run)
helm install my-release oci://ghcr.io/willbrid/charts/<chart-name> \
  --version <version> --dry-run

# Pull the chart locally
helm pull oci://ghcr.io/willbrid/charts/<chart-name> --version <version>
```

---

## Upgrade & uninstall

```bash
# Upgrade an existing release
helm upgrade my-release oci://ghcr.io/willbrid/charts/<chart-name> \
  --version <version> --values my-values.yaml

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
| `release` | Push to `main` | Package & publish charts to GHCR (OCI) |

A chart is only released when its `version` in `Chart.yaml` is bumped: the `release` workflow is
triggered by a change to `charts/**/Chart.yaml`, and only the charts whose `Chart.yaml` changed in
the push are packaged. Editing templates or values alone runs the tests, never the release.

### Holding a chart back from release

A chart under development lives in `charts/` and goes through lint and install like any other, but
it must not be pushed to the registry yet. The publication switch is an annotation of its
`Chart.yaml`:

```yaml
annotations:
  charthouse.io/release: "false"   # "true", or annotation absent, publishes the chart
```

The `release` workflow skips those charts when it selects what to package, including on a manual
`workflow_dispatch` run — which processes every chart of the repository. Flip the value to `"true"`
(or drop the annotation) when the chart is ready for its first publication.

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
