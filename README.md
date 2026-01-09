# OpenOps Helm Chart

This repository contains the Helm chart that deploys the OpenOps application stack (nginx, app server, engine, tables, analytics, Postgres, Redis) onto a Kubernetes cluster.

> **Note**: This chart is a work in progress and may not be production-ready.

## Repository layout
- `chart/Chart.yaml`: Chart metadata for the `openops` release.
- `chart/values.yaml`: Default configuration values.
- `chart/values.overrides-example.yaml`: Sample overrides file to copy and customize.
- `chart/templates/`: Kubernetes manifests templated by Helm.

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

## Storage
The chart provisions PersistentVolumeClaims for:
- PostgreSQL data (20Gi)
- Redis data (5Gi)
- Tables data (10Gi)

Customize storage classes and sizes via `chart/values.yaml` or your overrides file.

## Networking
- The `nginx` service is exposed as a `LoadBalancer` on port 80.
- All other services use `ClusterIP` for internal communication.
- The nginx configuration routes traffic to the appropriate backend services.

## Dependencies
The deployments include health checks and readiness probes so dependent services wait until their prerequisites are available.

