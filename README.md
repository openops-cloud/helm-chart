# OpenOps Helm Chart

This repository contains the Helm chart that deploys the OpenOps application stack (nginx, app server, engine, tables, analytics, Postgres, Redis) onto a Kubernetes cluster.

> **Note**: This chart is a work in progress and may not be production-ready.

## Repository layout
- `chart/Chart.yaml`: Chart metadata for the `openops` release.
- `chart/values.yaml`: Default configuration values.
- `chart/values.overrides-example.yaml`: Sample overrides file to copy and customize.
- `chart/values.ci.yaml`: Resource-constrained overlay for CI environments.
- `chart/values.production.yaml`: Production overlay with externalized dependencies and cloud settings.
- `chart/templates/`: Kubernetes manifests templated by Helm (21 files including deployments, services, configmaps, secrets, PVCs, ingress, and helpers).

## Components
- **nginx**: Reverse proxy and load balancer exposed via `LoadBalancer`.
- **openops-app**: Main application server.
- **openops-engine**: Task execution engine.
- **openops-tables**: Data tables service (Baserow).
- **openops-analytics**: Analytics dashboard (Superset).
- **postgres**: PostgreSQL database.
- **redis**: Redis cache.

## Quick start
1. Copy the sample overrides file and adjust it to match your environment:
   ```bash
   cp chart/values.overrides-example.yaml values.overrides.yaml
   ```
2. Install (or upgrade) the chart into your target namespace:
   ```bash
   helm upgrade --install openops ./chart -n openops --create-namespace -f values.overrides.yaml
   ```
3. Retrieve the external endpoint exposed by the nginx service to access the application:
   ```bash
   kubectl get svc nginx -n openops
   ```

## Secret hardening
- All sensitive environment keys are rendered through a shared Kubernetes `Secret` so containers never embed credentials in-line.
- Control how that secret is managed via the `secretEnv` block (disable creation, mark it `immutable`, or attach compliance labels/annotations).
- When `secretEnv.existingSecret` is set (optionally with `create: false`), the chart references the externally managed secret, which is recommended for SOPS, ExternalSecrets, or Vault-driven workflows.
- Values added under `secretEnv.stringData` stay in plain text for readability, while entries under `secretEnv.data` are templated and base64-encoded by the chart before being stored.
- Workloads automatically receive a `checksum/secret-env` pod annotation so any change to the secret triggers a rolling restart.

Example override:
```yaml
secretEnv:
  create: false
  existingSecret: openops-env
  immutable: true
  annotations:
    secrets.kubernetes.io/managed-by: external
```

## Multi-environment deployments
Use overlays to configure different environments:

**Development (default):**
```bash
helm upgrade --install openops ./chart -n openops-dev \
  -f chart/values.yaml \
  -f values.overrides.yaml
```

**CI/Testing:**
```bash
helm upgrade --install openops ./chart -n openops-ci \
  -f chart/values.yaml \
  -f chart/values.ci.yaml \
  -f values.overrides.yaml
```

**Production (externalized dependencies):**
```bash
helm upgrade --install openops ./chart -n openops-prod \
  -f chart/values.yaml \
  -f chart/values.production.yaml \
  -f values.overrides.yaml
```

The `values.production.yaml` overlay demonstrates:
- Externalized PostgreSQL (AWS RDS, GCP Cloud SQL, Azure Database)
- Externalized Redis (AWS ElastiCache, GCP Memorystore, Azure Cache)
- Cloud-specific storage classes and annotations
- Production-grade resource allocations and replica counts
- Security and logging best practices

## Storage
The chart uses StatefulSets with volumeClaimTemplates for stateful dependencies:
- **PostgreSQL**: 20Gi persistent storage (StatefulSet)
- **Redis**: 5Gi persistent storage (StatefulSet)
- **Tables**: 10Gi persistent storage (PVC)

### StatefulSet benefits
- **Stable network identities**: Each pod gets a predictable DNS name
- **Ordered rollouts**: Pods are updated sequentially for safe state transitions
- **Per-pod storage**: Each replica has its own dedicated PersistentVolumeClaim
- **Safe scaling**: Controlled pod creation and deletion order

### Storage customization
Customize storage classes, sizes, and backup annotations:
```yaml
postgres:
  storage:
    size: 50Gi
    storageClass: "gp3"
    annotations:
      snapshot.storage.kubernetes.io/enabled: "true"
  backup:
    annotations:
      backup.velero.io/backup-volumes: data
```

### Authentication and TLS
Both Postgres and Redis support optional authentication and TLS:
```yaml
postgres:
  auth:
    enabled: true
    existingSecret: "postgres-auth"
  tls:
    enabled: true
    existingSecret: "postgres-tls"
    caFile: true

redis:
  auth:
    enabled: true
    existingSecret: "redis-auth"
  tls:
    enabled: true
    existingSecret: "redis-tls"
```

### Update strategies
StatefulSets support partitioned rollouts for extra safety:
```yaml
postgres:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 1  # Update pods with ordinal >= partition
```

## Networking
- The `nginx` service is exposed as a `LoadBalancer` on port 80 by default.
- All other services use `ClusterIP` for internal communication.
- The nginx configuration routes traffic to the appropriate backend services.
- An optional `Ingress` resource can be enabled for environments using an ingress controller instead of a LoadBalancer.

## Dependencies
The deployments include health checks and readiness probes so dependent services wait until their prerequisites are available.

## Observability
The chart provides comprehensive observability features for monitoring, logging, and testing:

### Metrics and monitoring
Enable Prometheus ServiceMonitor resources for metrics collection:
```yaml
observability:
  metrics:
    enabled: true
    serviceMonitor:
      interval: 30s
      scrapeTimeout: 10s
      labels:
        prometheus: kube-prometheus
```

Individual components can be enabled/disabled:
```yaml
observability:
  metrics:
    components:
      app:
        enabled: true
        port: 80
        path: /api/v1/health
      postgres:
        enabled: false
```

### Log shipping
Configure log shipping annotations for integration with Fluentd, Fluent Bit, Promtail, or other log collectors:
```yaml
observability:
  logs:
    enabled: true
    format: json
    annotations:
      fluentd.io/include: "true"
      fluentd.io/multiline: "true"
```

### Helm tests
Run health checks and database readiness tests:
```bash
helm test openops -n openops
```

Configure which tests to run:
```yaml
observability:
  tests:
    enabled: true
    components:
      app:
        enabled: true
      engine:
        enabled: true
    database:
      postgres:
        enabled: true
      redis:
        enabled: true
```

## Topology and rollout safeguards
The chart provides built-in safeguards to avoid single-node concentration and ensure safe rolling updates:

### Deployment strategy
All deployments use a `RollingUpdate` strategy with configurable parameters (default: `maxSurge: 1`, `maxUnavailable: 0`) to ensure zero-downtime deployments.

### Topology spread constraints
When enabled (default), pods are distributed across nodes to avoid concentration on a single node:
- **maxSkew**: Maximum difference in pod count between nodes (default: 1)
- **topologyKey**: Topology domain key (default: `kubernetes.io/hostname`)
- **whenUnsatisfiable**: Scheduling behavior when constraint cannot be met (default: `ScheduleAnyway`)

Disable topology spread constraints:
```yaml
global:
  topologySpreadConstraints:
    enabled: false
```

### Pod anti-affinity
Optional pod anti-affinity rules can be enabled to prefer scheduling pods on different nodes:
```yaml
global:
  affinity:
    enabled: true
```

### Priority classes
Assign priority classes to pods for better scheduling control:
```yaml
global:
  priorityClassName: "high-priority"
```

### Customizing safeguards
Override the defaults in your values file:
```yaml
global:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 1
  
  topologySpreadConstraints:
    enabled: true
    maxSkew: 2
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
  
  affinity:
    enabled: true
  
  priorityClassName: "system-cluster-critical"
```

