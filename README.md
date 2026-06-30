# Apache Druid sandbox on kind

A local, end-to-end Apache Druid environment that runs on a [kind](https://kind.sigs.k8s.io)
cluster. Druid runs ZooKeeper-less and middle-manager-less (ingestion tasks run as
Kubernetes pods via the K8s task runner). Everything is wired together by a single
`Makefile`.

## What gets deployed

| Component | Chart / source | Namespace | Role |
|-----------|----------------|-----------|------|
| kind cluster + local registry | `config.yaml`, `kind-registry.sh` | — | 1 control-plane + 2 workers; insecure HTTP registry at `localhost:5001` |
| druid-operator | `charts/druid-operator` (public `datainfrahq/druid-operator` image) | `druid-operator-system` | Ships the `Druid` CRD and reconciles the CR into pods |
| garage | `charts/garage` | `garage` | S3-compatible object store — Druid deep storage + task logs |
| postgresql | `charts/postgresql` | `default` | Druid metadata store |
| kafka | `charts/kafka` | `kafka` | Single-broker KRaft Kafka for streaming ingestion |
| druid | `charts/druid` | `druid` | The Druid cluster (`Druid` custom resource) |

See [`charts/README.md`](charts/README.md) for chart-level detail and how the
pieces are wired (S3 endpoint, JDBC URI, credentials).

## Prerequisites

- Docker/Podman, [`kind`](https://kind.sigs.k8s.io), `kubectl`, [`helm`](https://helm.sh) 3+, `openssl`.
- No default StorageClass setup needed — kind provides `standard`.

## Quick start

```sh
make up           # kind cluster (+registry) -> operator -> garage -> postgres -> kafka -> druid
make garage-init  # initialize garage: layout + druid bucket + access key (run once, before ingesting)
make status       # show pods across all namespaces
```

Then submit an MSQ ingestion against the Druid router/broker (port-forward or via
the web console), or use Kafka-based ingestion with bootstrap servers
`kafka.kafka.svc.cluster.local:9092`.

Tear down:

```sh
make down         # delete the kind cluster
make clean        # delete the cluster and remove the local registry container
```

Run `make help` to list all targets. Individual steps are also targets:
`make cluster | operator | garage | postgres | kafka | druid`.

## Repo layout

```
.
├── Makefile            # end-to-end orchestration (see `make help`)
├── config.yaml         # kind cluster config (1 control-plane + 2 workers)
├── kind-registry.sh    # creates the cluster + an insecure local HTTP registry
├── data/               # host dir mounted into the control-plane at /mnt/data
└── charts/
    ├── README.md       # chart details + wiring
    ├── druid-operator/ # the operator (vendored chart, public image)
    ├── garage/         # S3 deep storage
    ├── postgresql/     # metadata store
    ├── kafka/          # KRaft Kafka broker (streaming ingestion)
    └── druid/          # the Druid cluster CR
```

## Local image registry

`kind-registry.sh` runs a registry at `localhost:5001` and configures containerd
on each node (via per-node `hosts.toml`) to pull from it insecurely over HTTP.
Push your own images as `localhost:5001/<name>:<tag>` and reference them from
manifests. (containerd 2.x ignores the inline `registry.mirrors` config, so the
`hosts.toml` style is used.)

## Credentials (sandbox only — plaintext)

These defaults live in the chart `values.yaml` files and are fine for a local
sandbox; use Kubernetes Secrets for anything real.

| Where | User / Key | Secret |
|-------|------------|--------|
| Postgres (metadata) | `druid` (db `druid`) | `mySuperSecret@1234` |
| Garage (S3) | `GK2e8295da0aa89eb42f531c44` | 64-hex secret in `charts/druid/values.yaml` |

The S3 keys must match between `charts/druid/values.yaml` (`deepStorage.s3.*`) and
the `Makefile` (`S3_ACCESS_KEY`/`S3_SECRET_KEY`, used by `make garage-init`).
Regenerate with garage's key format:

```sh
echo "GK$(openssl rand -hex 12)"   # access key
openssl rand -hex 32               # secret key
```
