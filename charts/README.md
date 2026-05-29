# Druid-on-kind Helm charts

Three small charts that, together with the **druid-operator**, stand up an Apache
Druid cluster on a local kind cluster (ZooKeeper-less, middle-manager-less /
Kubernetes task runner topology).

The whole stack is wired up by the repo-root [`Makefile`](../Makefile) — see
[End-to-end with the Makefile](#end-to-end-with-the-makefile). The tables below
document the individual pieces.

| Component | Role | Default namespace | In-cluster address |
|-----------|------|-------------------|--------------------|
| [`druid-operator`](./druid-operator) | Reconciles the `Druid` CR into pods; ships the `Druid` CRD (public `datainfrahq/druid-operator` image) | `druid-operator-system` | n/a |
| [`garage`](./garage) | S3-compatible object store — Druid **deep storage** + task logs | `garage` | `garage.garage.svc.cluster.local:3900` |
| [`postgresql`](./postgresql) | Druid **metadata store** | `default` | `postgres.default.svc.cluster.local:5432` |
| [`druid`](./druid) | The Druid cluster (a `Druid` custom resource) | `druid` | router/broker via the operator |

```
          ┌──────────────┐     metadata (JDBC)     ┌────────────────┐
          │    druid     │ ──────────────────────► │   postgresql   │
          │ (Druid CR)   │                          │  (default ns)  │
          │  (druid ns)  │ ── deep storage (S3) ──► ┌────────────────┐
          └──────────────┘                          │     garage     │
                                                     │  (garage ns)   │
                                                     └────────────────┘
```

## Prerequisites

- `kind`, `kubectl`, `helm` 3+, and Docker.
- A default `StorageClass` named `standard` (kind provides this).
- The **druid-operator** running, which both ships the `Druid` CRD and reconciles
  the `Druid` resource into pods. The `make operator` target installs the
  [`druid-operator`](./druid-operator) chart using the public
  `datainfrahq/druid-operator` image (no local build). Without the operator, the
  `druid` chart's CR is created but never turned into pods.

## End-to-end with the Makefile

The repo-root `Makefile` runs the whole sequence:

```sh
make up           # kind cluster (+registry) -> operator -> garage -> postgres -> druid
make garage-init  # initialize garage (layout + druid bucket + access key) before ingesting
make status       # show pods across all namespaces
make down         # delete the kind cluster
```

Individual steps are also targets: `make cluster | operator | garage | postgres | druid`.

## Install order (manual equivalent)

deep storage and metadata must exist before Druid starts, and the operator must
be present to reconcile the CR. So install in this order.

```sh
# 0. Cluster + local registry, then the operator (charts/druid-operator)
./kind-registry.sh
helm install druid-operator charts/druid-operator -n druid-operator-system --create-namespace

# 1. Object store (deep storage)
helm install garage charts/garage -n garage --create-namespace

# 2. Metadata store — auth.database=druid auto-creates the DB Druid expects
helm install postgres charts/postgresql -n default \
  --set auth.database=druid

# 3. The Druid cluster (operator reconciles it)
helm install druid charts/druid -n druid --create-namespace
```

## How the charts are wired together

The connection points are hardcoded service FQDNs, so the **release names and
namespaces above matter**. If you change them, update the matching values in the
`druid` chart.

| Druid value (`charts/druid/values.yaml`) | Default | Must match |
|------------------------------------------|---------|-----------|
| `deepStorage.s3.endpointUrl` | `http://garage.garage.svc.cluster.local:3900` | garage Service name/namespace/port |
| `deepStorage.s3.signingRegion` / `garage.s3Region` | `garage` | garage `garage.s3Region` |
| `deepStorage.bucket`, `indexerLogs.bucket` | `druid` | a bucket created in garage |
| `deepStorage.s3.accessKey` / `secretKey` | `GK0b…` / `c85b…` | an S3 key created in garage |
| `metadata.connectURI` | `…//postgres.default.svc.cluster.local/druid` | postgresql Service name/namespace + DB |
| `metadata.user` / `metadata.password` | `druid` / `mySuperSecret@1234` | postgresql `auth.username` / `auth.password` |

## Post-install steps

These are external to Helm (they create state inside garage / Postgres):

1. **Initialize garage** (empty layout on first start) and **create the bucket +
   access key** Druid uses. `make garage-init` does this: assigns/applies the
   layout, creates the `druid` bucket, and imports an S3 key matching the `druid`
   chart's `deepStorage.s3.accessKey`/`secretKey`. The exact `garage` CLI flags
   depend on the garage version (the target targets v2.x).
2. **Database**: installing postgresql with `--set auth.database=druid` creates
   the `druid` database. If you skip that flag, create it manually, otherwise
   Druid cannot connect.

## Notes / gotchas baked into the `druid` chart defaults

- `indexerLogs.disableAcl=true` and `deepStorage.disableAcl=true` — required for
  S3-compatible stores like garage that return a null ACL owner (otherwise
  segment/task-log pushes fail with a NullPointerException).
- `processing.*` buffers are set in the **common** properties so MSQ task peons
  (which never read per-node properties) don't auto-size huge buffers and get
  OOM-killed.
- `AWS_JAVA_V1_DISABLE_DEPRECATION_ANNOUNCEMENT=true` is set as an env var so it
  also reaches the generated task peon pods.

## Uninstall

```sh
helm uninstall druid -n druid
helm uninstall postgres -n default
helm uninstall garage -n garage
```

PVC retention differs per chart:

- **postgresql** keeps its PVC by default (`persistence.retain=true`). To let it
  be deleted with the release, set `persistence.retain=false` before uninstalling.
- **garage** PVCs come from the StatefulSet `volumeClaimTemplates`; Helm does not
  delete those on uninstall — remove them manually if you want a clean slate
  (`kubectl delete pvc -n garage -l app=garage`).
