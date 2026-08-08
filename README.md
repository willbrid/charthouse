# 🏠 charthouse

[![CI](https://github.com/willbrid/charthouse/actions/workflows/lint-test.yml/badge.svg?branch=main)](https://github.com/willbrid/charthouse/actions/workflows/lint-test.yml)
[![Release](https://github.com/willbrid/charthouse/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/willbrid/charthouse/actions/workflows/release.yml)

> Helm chart repository — infrastructure as code, shipped with GitHub Actions.

Charts are automatically packaged and published as OCI artifacts to [GitHub Container Registry](https://ghcr.io) via [`chart-releaser`](https://github.com/helm/chart-releaser).

---

## Prerequisites

| Requirement | Minimum version |
|-------------|-----------------|
| Kubernetes | `1.30` |
| Helm | `3.8` |

```bash
# Check both versions
kubectl version
helm version --short   # must report v3.8.0 or later
```

Charts are distributed **only** as OCI artifacts on `ghcr.io` — there is no `helm repo add` index. A
Helm client older than `3.8` cannot pull them at all, so upgrade the client rather than looking for
a classic repository URL.

---

## Available charts

| Chart | Description | Version | Published | Documentation |
|-------|-------------|---------|-----------|---------------|
| `grafana` | A Helm chart for installing grafana in Kubernetes | `0.1.1` | ✅ | [README](charts/grafana/README.md) |
| `otelcollector` | A Helm chart for installing opentelemetry collector in Kubernetes | `0.1.0` | ✅ | [README](charts/otelcollector/README.md) |
| `fluentbit` | A Helm chart for installing fluent-bit in Kubernetes | `0.2.0` | ✅ | [README](charts/fluentbit/README.md) |
| `kafka` | A Helm chart for installing Apache Kafka in KRaft mode in Kubernetes | `0.1.0` | ✅ | [README](charts/kafka/README.md) |
| `redis` | A Helm chart for installing Redis OSS in cluster or sentinel mode in Kubernetes | `0.1.0` | ✅ | [README](charts/redis/README.md) |
| `netshoot` | A Helm chart for installing netshoot, a network troubleshooting toolbox, in Kubernetes | `0.1.0` | ✅ | [README](charts/netshoot/README.md) |

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
│   │   ├── ci/               # Test values for CI
│   │   └── docs/             # Example values per installation scenario
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
| `lint-test` | Pull request, push to `main` | Lint + install charts on a [kind](https://kind.sigs.k8s.io/) cluster |
| `release` | Push to `main` touching a `Chart.yaml` | Lint + install, then package & publish to GHCR (OCI) |

A chart is only released when its `version` in `Chart.yaml` is bumped: the `release` workflow is
triggered by a change to `charts/**/Chart.yaml`, and only the charts whose `Chart.yaml` changed in
the push are packaged. Editing templates or values alone runs the tests, never the release.

### Which charts a run covers

Both workflows work on a selection rather than on the whole repository, and they always agree on
it: what gets tested is what gets published.

| Situation | Charts covered |
|-----------|----------------|
| Pull request | The charts changed by the PR (`ct list-changed`) |
| Push to `main` | The charts appearing in the push diff — `release` further narrows this to those whose `Chart.yaml` changed |
| Manual `workflow_dispatch` | The charts named in the `charts` input, or every chart when it is left empty |

### Documentation-only changes

A chart `README.md` and its `docs/` directory hold no template and no value the chart renders, so
there is nothing for `ct` to lint or install. Touching them never starts a test run:

| Change | Result |
|--------|--------|
| Only `charts/**/README.md` or `charts/**/docs/**` | No workflow runs at all (`paths` filter) |
| Documentation **and** another chart's templates or values | The run covers that other chart only |
| Documentation **and** the same chart's `Chart.yaml` | The chart is tested, then released — a version bump is still a release |

`docs/` holds the example values files each chart documents, one markdown page per installation
scenario, linked from a table in the chart README. It is listed in every `.helmignore`, so the
examples travel with the git repository and never inside the packaged chart.

A manual `workflow_dispatch` naming charts explicitly ignores this filter: an operator asking for a
chart gets it tested, whatever changed in it.

The `charts` input of the `release` workflow accepts a comma-separated list, in either form:
`fluentbit,grafana` or `charts/fluentbit,charts/grafana`. An unknown name fails the run instead of
resolving to an empty selection, which would otherwise report success while publishing nothing.

Selections are resolved once, by [`.github/scripts/resolve-charts.sh`](.github/scripts/resolve-charts.sh),
shared by the two workflows so a manual release cannot test one set of charts and publish another.

### Holding a chart back from release

A chart under development lives in `charts/` and goes through lint and install like any other, but
it must not be pushed to the registry yet. The publication switch is an annotation of its
`Chart.yaml`:

```yaml
annotations:
  charthouse.io/release: "false"   # "true", or annotation absent, publishes the chart
```

The `release` workflow skips those charts when it selects what to package, whatever brought them
into the selection — including a manual `workflow_dispatch` run naming them explicitly. They are
still linted and installed by the test suite. Flip the value to `"true"` (or drop the annotation)
when the chart is ready for its first publication.

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
