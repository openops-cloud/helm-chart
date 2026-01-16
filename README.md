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

## Infrastructure service authentication
The chart enforces authentication for Redis and PostgreSQL to prevent unauthenticated access:

### Redis authentication
- **Password protection**: Redis requires authentication via `OPS_REDIS_PASSWORD` (stored in the shared secret).
- **TLS support**: Enable TLS encryption by setting `redis.auth.enableTLS: true` and providing certificates via `redis.auth.tlsCert`, `redis.auth.tlsKey`, and optionally `redis.auth.tlsCA`.
- **Connection URL**: The `openops.redisUrl` helper automatically includes the password in the connection string.

Example configuration:
```yaml
openopsEnv:
  OPS_REDIS_PASSWORD: your-secure-redis-password
  OPS_REDIS_TLS_ENABLED: "true"

redis:
  auth:
    enabled: true
    enableTLS: true
    # Provide TLS certificates via Kubernetes secrets
```

### PostgreSQL authentication
- **Password protection**: Postgres requires authentication via `POSTGRES_PASSWORD` (stored in the shared secret).
- **pg_hba.conf**: Network access is restricted to Kubernetes cluster IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) using `scram-sha-256` authentication. All other connections are rejected.
- **TLS support**: Enable TLS encryption by setting `postgres.auth.enableTLS: true` and providing certificates via `postgres.auth.tlsCert`, `postgres.auth.tlsKey`, and optionally `postgres.auth.tlsCA`.
- **SSL mode**: Configure client SSL mode via `OPS_POSTGRES_SSL_MODE` (prefer, require, verify-ca, verify-full).

Example configuration:
```yaml
openopsEnv:
  OPS_POSTGRES_PASSWORD: your-secure-postgres-password
  OPS_POSTGRES_SSL_MODE: require

postgres:
  auth:
    enableTLS: true
    # Provide TLS certificates via Kubernetes secrets
    # Custom pg_hba.conf rules can be overridden
    pgHbaConf: |
      local   all             all                                     scram-sha-256
      host    all             all             10.0.0.0/8              scram-sha-256
      host    all             all             0.0.0.0/0               reject
```

### Production deployments
For production environments using managed services (AWS RDS, GCP Cloud SQL, Azure Database, etc.):
- Set `postgres.replicas: 0` and `redis.replicas: 0` to disable bundled instances
- Configure external endpoints via `OPS_POSTGRES_HOST`, `OPS_REDIS_HOST`
- Enable TLS with `OPS_POSTGRES_SSL_MODE: require` and `OPS_REDIS_TLS_ENABLED: "true"`
- Managed services typically enforce authentication and TLS by default

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

