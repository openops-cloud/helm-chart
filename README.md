# OpenOps Helm Chart

This repository contains the Helm chart that deploys the OpenOps application stack (nginx, app server, engine, tables, analytics, Postgres, Redis) onto a Kubernetes cluster.

## Repository layout
- `chart/Chart.yaml`: Chart metadata for the `openops` release.
- `chart/values.yaml`: Default configuration values.
- `chart/values.overrides-example.yaml`: Sample overrides file to copy and customize.
- `chart/values.ci.yaml`: Resource-constrained overlay for CI environments.
- `chart/values.dev.yaml`: Development overlay for local development environments.
- `chart/values.production.yaml`: Production overlay with externalized dependencies and cloud settings.
- `chart/templates/`: Kubernetes manifests templated by Helm (43 files including deployments, statefulsets, services, configmaps, secrets, external secrets, PVCs, ingress, service accounts, PodDisruptionBudgets, HorizontalPodAutoscalers, NetworkPolicy, LimitRange, ServiceMonitor, Helm tests, and helpers).
- `chart/.helmignore`: Excludes development and repository files from packaged charts.
- `LICENSE`: Apache 2.0 license for this Helm chart.
- `docs/`: Deployment guides for AWS EKS, EKS Fargate, and other platforms.

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
   cp chart/values.overrides-example.yaml chart/values.overrides.yaml
   ```
2. Install (or upgrade) the chart into your target namespace:
   ```bash
   helm upgrade --install openops ./chart -n openops --create-namespace -f chart/values.overrides.yaml
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

### Sample values overlays

The chart includes several example overlay files to help you get started:

**`values.overrides-example.yaml`** - Basic configuration template
- Copy this file to create your own `values.overrides.yaml`
- Contains examples for secrets, URLs, and resource adjustments
- Safe defaults for single-node development environments
- Shows how to enable Ingress with TLS

**`values.ci.yaml`** - CI/testing environment overlay
- Resource-constrained settings for fast startup
- Reduced replica counts (all components set to 1)
- Lower memory/CPU requests and limits
- Suitable for automated testing in resource-limited CI runners
- Example usage in GitHub Actions, GitLab CI, Jenkins

**`values.production.yaml`** - Production-ready overlay
- Demonstrates externalized PostgreSQL and Redis (AWS RDS, ElastiCache, etc.)
- Increased replica counts for high availability (app: 3, engine: 3, nginx: 2)
- Production-grade resource allocations (2-4Gi memory per service)
- Cloud-specific storage classes (gp3, premium-rwo, managed-csi)
- LoadBalancer annotations for AWS/GCP/Azure
- Security hardening examples

### Creating custom overlays

**Staging environment example:**
```yaml
# values.staging.yaml
global:
  version: "1.0.0-rc.1"

openopsEnv:
  OPS_PUBLIC_URL: "https://staging.openops.example.com"
  OPS_ENVIRONMENT_NAME: "staging"
  OPS_LOG_LEVEL: debug
  OPS_POSTGRES_HOST: "staging-db.example.com"
  OPS_POSTGRES_DATABASE: openops_staging

# Moderate resource allocation
app:
  replicas: 2
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1000m"

# Use external staging database
postgres:
  replicas: 0
```

**Multi-region deployment example:**
```yaml
# values.us-east-1.yaml
openopsEnv:
  OPS_PUBLIC_URL: "https://us-east.openops.example.com"
  OPS_POSTGRES_HOST: "rds-us-east-1.example.com"
  OPS_REDIS_HOST: "elasticache-us-east-1.example.com"

nginx:
  service:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"

tables:
  storage:
    storageClass: "gp3"
```

### Overlay precedence and merging

Helm merges values files from left to right, with later files overriding earlier ones:

```bash
helm upgrade --install openops ./chart \
  -f chart/values.yaml \           # 1. Base defaults
  -f chart/values.production.yaml \ # 2. Production overlay
  -f values.overrides.yaml \        # 3. Your custom secrets/config
  -f values.region.yaml             # 4. Region-specific overrides
```

**Best practices:**
- Keep `values.yaml` as the base with sensible defaults
- Use environment overlays (`values.ci.yaml`, `values.production.yaml`) for environment-specific settings
- Store secrets in `values.overrides.yaml` or external secret managers
- Use separate overlay files for region, tenant, or customer-specific configurations
- Version control overlay files (except secrets) for reproducible deployments
- Document customizations in comments within overlay files

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

### Volume ownership fix for tables
The tables component includes an init container that automatically fixes volume ownership to ensure compatibility with non-root security contexts. The init container runs once on pod startup and sets the ownership of `/baserow/data` to `1000:1000` (matching the application's security context). This prevents permission errors when the main container tries to write to the mounted volume.

To customize or disable this init container, override the `tables.initContainers` value in your configuration.

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

### TLS/HTTPS configuration
Enable TLS termination using Kubernetes Ingress with cert-manager or cloud-managed certificates:

**Using Ingress with TLS:**
```yaml
ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: openops.example.com
      paths:
        - path: /
          pathType: Prefix
          serviceName: nginx
          servicePort: 80
  tls:
    - hosts:
        - openops.example.com
      secretName: openops-tls  # cert-manager will populate this
  tlsConfig:
    enabled: true  # enables HSTS, SSL redirect, and cipher configuration
    sslProtocols: "TLSv1.2 TLSv1.3"
    hstsMaxAge: "31536000"
    hstsIncludeSubdomains: "true"
    hstsPreload: "true"
```

**Cloud-specific LoadBalancer with SSL:**
For AWS NLB with ACM certificate:
```yaml
nginx:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:region:account:certificate/cert-id"
      service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
      service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
```

**Pre-created TLS secret:**
```bash
kubectl create secret tls openops-tls \
  --cert=/path/to/tls.crt \
  --key=/path/to/tls.key \
  -n openops
```

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

## Scaling and resource management

### Horizontal scaling
Scale replicas for individual components based on load:

```yaml
app:
  replicas: 3
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"

engine:
  replicas: 3

tables:
  replicas: 2

analytics:
  replicas: 2

nginx:
  replicas: 2
```

**Important scaling considerations:**
- **app** and **engine** are stateless and can be scaled horizontally without restrictions.
- **tables** uses file-based storage (SQLite for media) and requires `ReadWriteOnce` PVC; limit to 2-3 replicas or migrate to object storage.
- **analytics** can be scaled but shares session state; consider sticky sessions or external session storage for >2 replicas.
- **postgres** and **redis** bundled deployments are single-replica; use external managed services for HA.

### Vertical scaling
Adjust resource requests and limits per workload:

```yaml
app:
  resources:
    requests:
      memory: "2Gi"  # guaranteed resources
      cpu: "1000m"
    limits:
      memory: "4Gi"  # maximum allowed
      cpu: "2000m"
```

**Resource tuning guidelines:**
- **app**: Memory-intensive for large workflows; start with 1-2Gi, scale to 4Gi+ under load.
- **engine**: CPU-intensive for code execution; allocate 500m-1000m CPU per replica.
- **tables**: Initial migrations require 1-2Gi memory; steady-state can run on 512Mi-1Gi.
- **analytics**: Dashboard rendering is memory-heavy; allocate 2Gi+ for production.
- **postgres**: Size based on dataset; 512Mi-1Gi for dev, 2Gi+ for production.
- **redis**: Typically light; 256Mi-512Mi sufficient for most workloads.

### Autoscaling
The chart includes optional HorizontalPodAutoscaler (HPA) resources for app, engine, analytics, and nginx. Enable them in your values:

```yaml
hpa:
  enabled: true
  app:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80
  engine:
    enabled: true
    minReplicas: 2
    maxReplicas: 8
  analytics:
    enabled: true
    minReplicas: 1
    maxReplicas: 5
  nginx:
    enabled: true
    minReplicas: 2
    maxReplicas: 6
```

**Prerequisites:**
- Kubernetes Metrics Server must be installed in your cluster
- Resource requests must be defined for accurate scaling decisions

**Note:** When HPA is enabled, the `replicas` field in the deployment is ignored. The HPA manages replica count dynamically based on observed metrics.

## Production hardening

### Security best practices

**1. Secrets management**
Use external secret managers instead of storing secrets in values files:

```yaml
secretEnv:
  create: false
  existingSecret: openops-env  # managed by ExternalSecrets, SOPS, or Vault
  immutable: true
  annotations:
    secrets.kubernetes.io/managed-by: external-secrets
```

Create secrets using one of these methods:

**External Secrets Operator:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: openops-env
  namespace: openops
spec:
  secretStoreRef:
    name: aws-secrets-manager  # or vault, gcpsm, etc.
    kind: SecretStore
  target:
    name: openops-env
  data:
    - secretKey: OPS_ENCRYPTION_KEY
      remoteRef:
        key: openops/encryption-key
    - secretKey: OPS_JWT_SECRET
      remoteRef:
        key: openops/jwt-secret
```

**SOPS encryption:**
```bash
# Encrypt values file
sops --encrypt --kms arn:aws:kms:region:account:key/id values.overrides.yaml > values.overrides.enc.yaml

# Deploy with decryption
helm secrets upgrade --install openops ./chart -f values.overrides.enc.yaml
```

**Manual secret creation:**
```bash
kubectl create secret generic openops-env -n openops \
  --from-literal=OPS_ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --from-literal=OPS_JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=OPS_POSTGRES_PASSWORD="$(openssl rand -base64 32)" \
  --from-literal=OPS_OPENOPS_ADMIN_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=OPS_ANALYTICS_ADMIN_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=ANALYTICS_POWERUSER_PASSWORD="$(openssl rand -base64 24)"
```

**2. Network policies**
The chart includes a comprehensive NetworkPolicy that restricts pod-to-pod communication. Enable it in your values:

```yaml
networkPolicy:
  enabled: true
  # Allow ingress from specific namespaces (e.g., monitoring)
  allowedNamespaces:
    - monitoring
    - ingress-nginx
  # Allow egress to external services
  allowExternal: true
  # Custom egress rules
  extraEgress:
    - to:
      - namespaceSelector:
          matchLabels:
            name: external-api
      ports:
      - protocol: TCP
        port: 443
```

The default policy enforces:
- Nginx accepts traffic from LoadBalancer/Ingress and routes to app/analytics/tables
- App, engine, and analytics can access Postgres and Redis
- All components can query DNS and access external HTTPS endpoints
- Postgres and Redis only accept connections from authorized components
- All other traffic is denied by default (zero-trust networking)

**3. Pod Security Standards**
Apply restricted security context:

```yaml
app:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop:
      - ALL
```

**4. Resource limits and quotas**
The chart includes an optional LimitRange to set default resource constraints:

```yaml
limitRange:
  enabled: true
  limits:
    - type: Container
      default:
        cpu: "1000m"
        memory: "2Gi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "4000m"
        memory: "8Gi"
      min:
        cpu: "50m"
        memory: "64Mi"
    - type: PersistentVolumeClaim
      max:
        storage: "100Gi"
      min:
        storage: "1Gi"
```

Additionally, create a ResourceQuota at the namespace level to prevent resource exhaustion:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: openops-quota
  namespace: openops
spec:
  hard:
    requests.cpu: "20"
    requests.memory: "40Gi"
    limits.cpu: "40"
    limits.memory: "80Gi"
    persistentvolumeclaims: "5"
```

**5. Service accounts and IRSA/Workload Identity**
Each component has a dedicated service account with configurable annotations:

```yaml
serviceAccount:
  app:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT:role/openops-app"
  engine:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT:role/openops-engine"
  # For GCP Workload Identity
  analytics:
    create: true
    annotations:
      iam.gke.io/gcp-service-account: "openops-analytics@PROJECT.iam.gserviceaccount.com"
```

**6. Image security**
- Use specific image tags (not `latest`)
- Enable image pull secrets for private registries
- Scan images for vulnerabilities with Trivy or Snyk
- Use distroless or minimal base images

```yaml
image:
  repository: your-registry.example.com/openops
  pullPolicy: IfNotPresent
  pullSecrets:
    - name: registry-credentials

global:
  version: "1.0.0"  # explicit version, not 'latest'
```

**7. Audit logging**
Enable Kubernetes audit logs and application logging:

```yaml
openopsEnv:
  OPS_LOG_LEVEL: warn  # reduce noise in production
  OPS_LOG_PRETTY: "false"  # JSON for log aggregation
  OPS_TELEMETRY_MODE: COLLECTOR
```

**8. Database security**
- Use SSL/TLS for database connections
- Enable encryption at rest for managed databases
- Rotate database credentials regularly
- Limit database user permissions to minimum required

**9. Regular updates**
- Monitor security advisories for dependencies
- Update Helm chart and application versions regularly
- Test updates in staging before production deployment

### High availability setup

For production deployments with zero-downtime requirements:

```yaml
# Use external managed services for stateful components
postgres:
  replicas: 0  # disabled; use AWS RDS/GCP Cloud SQL/Azure Database

redis:
  replicas: 0  # disabled; use AWS ElastiCache/GCP Memorystore/Azure Cache

# Scale stateless components
app:
  replicas: 3
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"

engine:
  replicas: 3

tables:
  replicas: 2

analytics:
  replicas: 2

nginx:
  replicas: 2

# Enable anti-affinity and topology spread
global:
  affinity:
    enabled: true
  topologySpreadConstraints:
    enabled: true
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule

# Enable PodDisruptionBudgets
pdb:
  enabled: true
  app:
    enabled: true
    minAvailable: 2
  engine:
    enabled: true
    minAvailable: 2
  nginx:
    enabled: true
    minAvailable: 1
  analytics:
    enabled: true
    minAvailable: 1
  tables:
    enabled: true
    minAvailable: 1
```

### Monitoring and observability

**Prometheus metrics:**
The chart includes a ServiceMonitor resource for Prometheus Operator integration. Enable it in your values:

```yaml
serviceMonitor:
  enabled: true
  interval: 30s
  scrapeTimeout: 10s
  additionalLabels:
    release: prometheus  # match your Prometheus Operator's serviceMonitorSelector
  honorLabels: true
```

The ServiceMonitor automatically discovers and scrapes metrics from:
- `openops-app` on `/metrics`
- `openops-engine` on `/metrics`
- `openops-analytics` on `/metrics`
- `postgres` on `:9187/metrics` (if postgres-exporter sidecar is enabled)
- `redis` on `:9121/metrics` (if redis-exporter sidecar is enabled)

**Liveness and readiness probes:**
All components include default health checks. Customize if needed:

```yaml
app:
  livenessProbe:
    httpGet:
      path: /health
      port: 8080
    initialDelaySeconds: 30
    periodSeconds: 10
  readinessProbe:
    httpGet:
      path: /ready
      port: 8080
    initialDelaySeconds: 10
    periodSeconds: 5
```

**Helm tests:**
Validate your deployment with built-in Helm tests:

```bash
helm test openops -n openops
```

The test suite verifies:
- Nginx service is reachable
- App service responds to health checks
- Database connectivity (if in-cluster Postgres is enabled)
- Redis connectivity (if in-cluster Redis is enabled)

### Backup and disaster recovery

**Database backups:**
```bash
# PostgreSQL backup using pg_dump
kubectl exec -n openops postgres-0 -- pg_dumpall -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# Restore from backup
gunzip < backup-20260116.sql.gz | kubectl exec -i -n openops postgres-0 -- psql -U postgres
```

For managed databases, use cloud-native backup solutions:
- AWS RDS: Automated backups and snapshots
- GCP Cloud SQL: Automated backups and point-in-time recovery
- Azure Database: Automated backups with geo-redundancy

**PVC snapshots:**
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: tables-snapshot
  namespace: openops
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: tables-pvc
```

