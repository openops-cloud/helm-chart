# AGENTS

## Repository structure
- `/chart/Chart.yaml`: Helm chart metadata (name, version, description). **Do not bump the version manually**—it is updated automatically during release workflows.
- `/chart/values.yaml`: Default configuration for all OpenOps components; use it to learn the expected keys before adding overrides.
- `/chart/values.overrides-example.yaml`: Reference file that shows how to structure your own overrides file for deployments.
- `/chart/values.ci.yaml`: Resource-constrained overlay for CI environments.
- `/chart/values.dev.yaml`: Development overlay for local development environments.
- `/chart/values.production.yaml`: Production overlay with externalized dependencies and cloud settings.
- `/chart/templates/`: Kubernetes manifests rendered by Helm (43 files). Includes deployments/statefulsets, services, configmaps (`configmap-*.yaml`), secrets (`secret-env.yaml`, `external-secret.yaml`), service accounts, PodDisruptionBudgets, HorizontalPodAutoscalers, NetworkPolicy, LimitRange, ServiceMonitor for Prometheus, and Helm tests. Shared template helpers live in `_helpers.tpl` (561 lines with 49+ helper functions). Postgres and Redis use StatefulSets with volumeClaimTemplates for stable storage and safe rollouts.
- `/chart/templates/NOTES.txt`: Helm installation notes displayed after deployment with important warnings and next steps.
- `/chart/.helmignore`: Excludes development and repository files from packaged charts to reduce size and prevent leaking unnecessary files.
- `/LICENSE`: Apache 2.0 license for this Helm chart repository.
- `/README.md`: Comprehensive documentation covering installation, configuration, operational toggles (secrets, TLS, scaling, production hardening), and multi-environment deployments.
- `/docs/`: Deployment guides including AWS EKS (EC2), AWS EKS Fargate, and platform-specific instructions.
- `/.github/prlint.json`: Pull-request lint configuration (see below) that runs in CI to enforce title/body rules.
- `/.github/workflows/`: Automation (tests, lint, release) triggered by pushes and pull requests. Update these only when you need to change CI behavior.

## Stateful dependencies
- **Postgres and Redis** are deployed as StatefulSets with volumeClaimTemplates for per-pod persistent storage, ordered rollouts, and stable network identities.
- Both support optional authentication, TLS encryption, and backup annotations for production use.
- Set `replicas: 0` in production overlays to use external managed services (AWS RDS, ElastiCache, etc.) instead of in-cluster instances.
- **Tables** uses a PersistentVolumeClaim for `/baserow/data` and includes an init container to fix volume ownership (uid:gid 1000:1000) to ensure compatibility with non-root security contexts.

## Production features
- **Security-first design**: Security contexts enabled by default (runAsNonRoot, drop ALL capabilities, seccomp RuntimeDefault profile).
- **Service accounts**: Dedicated service accounts for each component (app, engine, tables, analytics, nginx, postgres, redis) with configurable annotations for AWS IAM roles (IRSA), GCP Workload Identity, or Azure Managed Identity.
- **External Secrets Operator**: Built-in support for AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager, and Azure Key Vault integration.
- **PodDisruptionBudgets (PDBs)**: Configured for all stateless components to ensure minimum availability during voluntary disruptions (node drains, upgrades).
- **HorizontalPodAutoscalers (HPAs)**: Optional autoscaling for app, engine, analytics, and nginx based on CPU/memory metrics.
- **NetworkPolicy**: Optional network segmentation to restrict pod-to-pod communication and enforce least-privilege networking with explicit allow rules.
- **LimitRange**: Optional namespace-level resource defaults and constraints to prevent resource exhaustion.
- **ServiceMonitor**: Prometheus Operator integration for scraping application metrics from `/metrics` endpoints.
- **Helm tests**: Post-installation connectivity tests to validate deployment health.
- **Validation helpers**: Runtime validation of required secrets (OPS_ENCRYPTION_KEY, OPS_JWT_SECRET, etc.) with helpful error messages at render time.

## Release workflow
- **`.github/workflows/release.yml`**: Packages the Helm chart and pushes it as an OCI artifact to `public.ecr.aws/openops/helm`.
- Triggered via `workflow_dispatch` with two inputs:
  - `version` (required): The release version (e.g., `0.6.15`). Sets both `Chart.yaml` version/appVersion and `global.version` (image tags).
  - `draft` (boolean, default `true`): When true, appends `-draft` to the chart version (e.g., `0.6.15-draft`). Draft versions are overwritable on ECR; final versions are immutable.
- Also triggered cross-repo by `openops-cloud/openops` release workflow.
- Creates a GitHub release (draft or published) with the packaged `.tgz` as an asset.
- **Do not bump versions in `Chart.yaml` or `values.yaml` manually**—the release workflow sets them at build time. The repo defaults are `0.0.1-dev` / `0.0.1-dev`.
- Required secrets: `ECR_ACCESS_KEY_ID`, `ECR_SECRET_ACCESS_KEY`; required vars: `ECR_PUBLIC_REGION`.

## Versioning strategy
- All versions are unified: chart version = appVersion = `global.version` (image tags) = OpenOps release version.
- Exception: draft releases use `{version}-draft` for the chart version only; `appVersion` and image tags use the clean version.
- The chart is published to `oci://public.ecr.aws/openops/helm`. Users install with:
  ```
  helm install openops oci://public.ecr.aws/openops/helm --version <VERSION>
  ```

## PR lint rules
The `.github/prlint.json` ruleset runs on every pull request. To avoid CI failures:
1. **Title requirements**
   - Start with a capitalized real word (`Add`, `Fix`, `Update`, etc.).
   - Contain at least three words so reviewers immediately understand the change.
   - Use the imperative mood ("Add support for X" rather than "Added" or "Adding").
2. **Body requirements**
   - Reference the tracking item with one of `Fixes|Resolves|Closes|Part of` followed by either a GitHub issue (`#1234`) or a Linear ticket (`OPS-1234`, `OPC-1234`, `CI-1234`, `DOC-1234`).
   - For dependency bumps, "Dependabot commands and options" is also accepted.

## License
This Helm chart repository is licensed under the Apache License 2.0. See the LICENSE file for full terms.

## Documentation updates
- **Update both AGENTS.md and README.md** with every PR if there are relevant changes to repository structure, workflows, guidelines, or usage instructions.
- Keep documentation synchronized with code changes to ensure agents and users have accurate information.
- The chart is production-ready and follows enterprise-grade best practices for security, high availability, and observability.

## Commit guidelines
- Write commit subjects in the imperative mood, mirroring the PR title rules (e.g., "Add Redis PVC annotations").
- Capitalize the first word and keep the subject ≤ 72 characters; add a blank line before the body.
- Use the body to explain *what* and *why*, wrapping at ~72 characters per line for readability.
- Reference relevant issues in the body when closing or relating work (same keywords as PR bodies).
- Prefer focused commits that touch a single logical change; this keeps review and potential rollbacks simple.
