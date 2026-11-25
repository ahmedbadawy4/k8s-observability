# k8s-observability

A reference observability stack for Kubernetes. Applications send OpenTelemetry (OTLP) metrics and traces to Grafana Alloy. Alloy writes the metrics to Prometheus and the traces to Tempo. Grafana shows both. A small Helm chart adds service level objective (SLO) alerts that use multi-window, multi-burn-rate rules.

It runs on a local [kind](https://kind.sigs.k8s.io/) cluster with one command. It is a reference setup for learning and as a starting point. It is not a production setup. See [Limits](#limits).

## What it installs

| Part | Installed with | Purpose |
|---|---|---|
| kube-prometheus-stack (release `kps`) | Helm, [`prometheus/values.yaml`](prometheus/values.yaml) | Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics |
| Grafana Alloy (release `alloy`) | Helm, [`alloy/values.yaml`](alloy/values.yaml) and [`alloy/config.alloy`](alloy/config.alloy) | OTLP gateway: receives telemetry, forwards it |
| Tempo | Plain manifests, [`tempo/tempo.yaml`](tempo/tempo.yaml) | Trace storage and search (single binary) |
| slo-rules (release `slo`) | Helm, [`charts/slo-rules`](charts/slo-rules) | SLO recording rules and burn-rate alerts |
| telemetrygen Job | Plain manifest, [`examples/telemetrygen.yaml`](examples/telemetrygen.yaml) | Smoke test that sends sample traces and metrics |

## How the data flows

```
application --OTLP gRPC :4317 / HTTP :4318--> Grafana Alloy
                                                |
                         +----------------------+----------------------+
                         | metrics                                     | traces
                         v                                             v
        Prometheus (remote write receiver)                  Tempo (OTLP gRPC :4317)
                         |                                             |
                         +------------------> Grafana <----------------+
                                                |
                         PrometheusRule (slo-rules) --> Alertmanager
```

- Alloy converts OTLP metrics to Prometheus samples and pushes them to `/api/v1/write` on Prometheus.
- Alloy forwards traces to Tempo over OTLP gRPC. Plain text is used inside the cluster.
- Prometheus loads the `slo-rules` PrometheusRule because `prometheus/values.yaml` turns off the release-name selectors.
- Grafana has a Tempo data source from `prometheus/values.yaml`.

## Run it

You need Docker, [kind](https://kind.sigs.k8s.io/), kubectl, Helm 3 or 4, openssl and make.

```bash
make up                    # kind cluster + the whole stack
make smoke                 # send test traces and metrics, check the metric in Prometheus
make grafana-password      # print the generated Grafana admin password
make port-forward-grafana  # Grafana on http://localhost:3000, user admin
make down                  # delete the cluster
```

`make help` lists every target. The Grafana admin password is generated at install time into the Secret `grafana-admin`, so no credentials are stored in this repository.

After `make smoke`:

- Grafana > Explore > Tempo: search for `service.name = telemetrygen`.
- Grafana > Explore > Prometheus: query `gen`.

## SLO alerts

The [`slo-rules`](charts/slo-rules) chart turns a list of SLOs into a `PrometheusRule`. Each SLO needs a name, an error budget and a PromQL query for the error ratio. `__WINDOW__` in the query is replaced with each window. The chart then writes:

- recording rules `slo:sli_error:ratio_rate<window>` for 5m, 30m, 1h, 2h, 6h, 1d and 3d
- four `SLOErrorBudgetBurn` alerts per SLO, for a 30 day objective window:

| Burn rate | Long window | Short window | Severity |
|---|---|---|---|
| 14.4 | 1h | 5m | critical |
| 6 | 6h | 30m | critical |
| 3 | 1d | 2h | warning |
| 1 | 3d | 6h | warning |

An alert fires when the error ratio is above `burn rate x error budget` in both the long and the short window. The thresholds follow the table in the Google SRE Workbook chapter "Alerting on SLOs".

The default SLO in [`charts/slo-rules/values.yaml`](charts/slo-rules/values.yaml) is the availability of the Kubernetes API server, because every kube-prometheus-stack cluster has that metric. To add a service, copy the commented example in that file and change the query. Check the result with:

```bash
make render
```

## Repository layout

```
.
├── Makefile                  commands: up, down, smoke, lint, render
├── kind/cluster.yaml         single-node kind cluster named "observability"
├── prometheus/values.yaml    kube-prometheus-stack values
├── alloy/
│   ├── config.alloy          Alloy pipeline (OTLP in, Prometheus and Tempo out)
│   └── values.yaml           Alloy chart values
├── tempo/tempo.yaml          Tempo ConfigMap, Deployment and Service
├── charts/slo-rules/         Helm chart for SLO rules and alerts
├── examples/telemetrygen.yaml  smoke test Job
└── .github/workflows/ci.yml  CI
```

## CI

[`ci.yml`](.github/workflows/ci.yml) runs on every push to `master` and on pull requests:

- `helm lint` and `helm template` for `charts/slo-rules`
- `promtool check rules` on the rendered rules (Prometheus v3.5.0)
- `kubeconform` on the Tempo manifest, the smoke test Job and the rendered `PrometheusRule`
- `alloy validate` on `alloy/config.alloy` (Alloy v1.22.0)

CI does not start a cluster. It checks that the files are valid, not that the stack runs. The cluster flow is `make up` and `make smoke`.

The same checks are available before a commit with [pre-commit](https://pre-commit.com/) (`.pre-commit-config.yaml`: YAML syntax, whitespace, private keys).

## Pinned versions

| Component | Version |
|---|---|
| kube-prometheus-stack chart | 93.9.0 |
| Grafana Alloy chart / Alloy | 1.16.0 / v1.22.0 |
| Tempo | 2.9.0 |
| telemetrygen | v0.162.0 |

Chart versions are set at the top of the [`Makefile`](Makefile).

## Limits

This is a reference setup. A production setup would change at least these points:

- **No persistent storage.** Tempo stores data on an `emptyDir`, and Prometheus uses the chart default (also not persistent here). Data is lost when a pod is replaced.
- **Short retention.** Prometheus keeps 2 days of data and Tempo keeps 24 hours. The 3d burn-rate windows cannot be fully evaluated with 2 days of data.
- **Single replicas.** Alloy, Tempo, Prometheus and Grafana each run once.
- **No TLS and no authentication** between the components. Only the Grafana admin login is protected.
- **No alert receiver.** Alerts show in Prometheus and Alertmanager. No notification target is configured.
- **Local only.** The kind cluster has one node. Control plane scrape targets (etcd, scheduler, controller manager, kube-proxy) are turned off because kind does not expose them.

## License

Apache License 2.0, see [LICENSE](LICENSE).
