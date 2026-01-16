# AGENTS

## Repository structure
- `/chart/Chart.yaml`: Helm chart metadata (name, version, description). **Do not bump the version manually**—it is updated automatically during release workflows.
- `/chart/values.yaml`: Default configuration for all OpenOps components; use it to learn the expected keys before adding overrides.
- `/chart/values.overrides-example.yaml`: Reference file that shows how to structure your own overrides file for deployments.
- `/chart/values.ci.yaml`: Resource-constrained overlay for CI environments.
- `/chart/values.production.yaml`: Production overlay with externalized dependencies and cloud settings.
- `/chart/templates/`: Kubernetes manifests rendered by Helm. Each service/component has its own deployment/statefulset and service files, along with shared helpers in `_helpers.tpl` and secrets/configmaps under `configmap-*.yaml`, `secret-env.yaml`, and `pvc-*.yaml`. Postgres and Redis use StatefulSets with volumeClaimTemplates for stable storage and safe rollouts. PodDisruptionBudgets (`pdb-*.yaml`) and HorizontalPodAutoscalers (`hpa-*.yaml`) are available for stateless services (app, engine, tables, analytics, nginx) but disabled by default.
- `/.github/prlint.json`: Pull-request lint configuration (see below) that runs in CI to enforce title/body rules.
- `/.github/workflows/`: Automation (tests, lint, release) triggered by pushes and pull requests. Update these only when you need to change CI behavior.

## Stateful dependencies
- **Postgres and Redis** are deployed as StatefulSets with volumeClaimTemplates for per-pod persistent storage, ordered rollouts, and stable network identities.
- Both support optional authentication, TLS encryption, and backup annotations for production use.
- Set `replicas: 0` in production overlays to use external managed services (AWS RDS, ElastiCache, etc.) instead of in-cluster instances.

## PR lint rules
The `.github/prlint.json` ruleset runs on every pull request. To avoid CI failures:
1. **Title requirements**
   - Start with a capitalized real word (`Add`, `Fix`, `Update`, etc.).
   - Contain at least three words so reviewers immediately understand the change.
   - Use the imperative mood ("Add support for X" rather than "Added" or "Adding").
2. **Body requirements**
   - Reference the tracking item with one of `Fixes|Resolves|Closes|Part of` followed by either a GitHub issue (`#1234`) or a Linear ticket (`OPS-1234`, `OPC-1234`, `CI-1234`, `DOC-1234`).
   - For dependency bumps, "Dependabot commands and options" is also accepted.

## Documentation updates
- **Update both AGENTS.md and README.md** with every PR if there are relevant changes to repository structure, workflows, guidelines, or usage instructions.
- Keep documentation synchronized with code changes to ensure agents and users have accurate information.

## Commit guidelines
- Write commit subjects in the imperative mood, mirroring the PR title rules (e.g., "Add Redis PVC annotations").
- Capitalize the first word and keep the subject ≤ 72 characters; add a blank line before the body.
- Use the body to explain *what* and *why*, wrapping at ~72 characters per line for readability.
- Reference relevant issues in the body when closing or relating work (same keywords as PR bodies).
- Prefer focused commits that touch a single logical change; this keeps review and potential rollbacks simple.

## Workload health and resilience
All stateless services (app, engine, tables, analytics, nginx) have:
- **Health probes**: Startup, readiness, and liveness probes configured appropriately for each service
- **Resource requests and limits**: CPU and memory allocations defined to ensure proper scheduling
- **Optional PDBs**: PodDisruptionBudgets (disabled by default) to protect against voluntary disruptions
- **Optional HPAs**: HorizontalPodAutoscalers (disabled by default) for automatic scaling based on CPU/memory metrics

To enable PDBs or HPAs, set `<service>.podDisruptionBudget.enabled: true` or `<service>.autoscaling.enabled: true` in values.yaml or your overrides file.

