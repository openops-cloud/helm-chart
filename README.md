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
- Secrets have been removed from default values and must be provided per-install for security.
- Each workload now has its own dedicated Kubernetes `Secret` for better isolation and security (app, engine, tables, analytics, postgres).
- Control secret management via the `secretEnv` block with per-workload configuration or use a shared secret (legacy).
- Set `create: false` and specify `existingSecret` to reference externally managed secrets (SOPS, External Secrets Operator, Vault, Sealed Secrets).
- Values added under `secretEnv.<component>.stringData` stay in plain text for readability, while entries under `secretEnv.<component>.data` are base64-encoded.
- Workloads automatically receive a `checksum/secret-env` pod annotation so any change to their secret triggers a rolling restart.

**Per-workload secrets (recommended):**
```yaml
secretEnv:
  app:
    stringData:
      OPS_ENCRYPTION_KEY: your-32-char-encryption-key-here
      OPS_JWT_SECRET: your-jwt-secret-here
      OPS_OPENOPS_ADMIN_PASSWORD: your-admin-password
  
  tables:
    stringData:
      SECRET_KEY: your-32-char-encryption-key-here
      BASEROW_JWT_SIGNING_KEY: your-jwt-secret-here
      BASEROW_ADMIN_PASSWORD: your-admin-password
      DATABASE_PASSWORD: your-database-password
  
  analytics:
    stringData:
      ADMIN_PASSWORD: your-analytics-admin-password
      POWERUSER_PASSWORD: your-analytics-poweruser-password
      DATABASE_PASSWORD: your-database-password
      SUPERSET_SECRET_KEY: your-32-char-encryption-key-here
  
  postgres:
    stringData:
      POSTGRES_PASSWORD: your-database-password
```

**External secrets (e.g., External Secrets Operator):**
```yaml
secretEnv:
  app:
    create: false
    existingSecret: openops-app-env
  tables:
    create: false
    existingSecret: openops-tables-env
  analytics:
    create: false
    existingSecret: openops-analytics-env
  postgres:
    create: false
    existingSecret: openops-postgres-env
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
The chart provisions PersistentVolumeClaims for:
- PostgreSQL data (20Gi)
- Redis data (5Gi)
- Tables data (10Gi)

Customize storage classes and sizes via `chart/values.yaml` or your overrides file.

## Networking
- The `nginx` service is exposed as a `LoadBalancer` on port 80 by default.
- All other services use `ClusterIP` for internal communication.
- The nginx configuration routes traffic to the appropriate backend services.
- An optional `Ingress` resource can be enabled for environments using an ingress controller instead of a LoadBalancer.

## Dependencies
The deployments include health checks and readiness probes so dependent services wait until their prerequisites are available.

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

