# OpenOps Helm Chart

This repository contains the Helm chart that deploys the OpenOps application stack (nginx, app server, engine, tables, analytics, Postgres, Redis) onto a Kubernetes cluster.

## Repository layout
- `chart/Chart.yaml`: Chart metadata for the `openops` release.
- `chart/values.yaml`: Default configuration values.
- `chart/values.overrides-example.yaml`: Sample overrides file to copy and customize.
- `chart/templates/`: Kubernetes manifests templated by Helm.

## Quick start
1. Copy the sample overrides file and adjust it to match your environment:
   ```bash
   cp chart/values.overrides-example.yaml values.overrides.yaml
   ```
2. Install (or upgrade) the chart into your target namespace:
   ```bash
   helm upgrade --install openops ./chart -n openops --create-namespace -f values.overrides.yaml
   ```
3. Retrieve the external endpoint exposed by the nginx service:
   ```bash
   kubectl get svc nginx -n openops
   ```

See `chart/README.md` for component details, storage guidance, and networking notes.
