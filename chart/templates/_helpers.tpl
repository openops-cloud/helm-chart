{{/*
Expand the name of the chart.
*/}}
{{- define "openops.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "openops.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "openops.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openops.labels" -}}
helm.sh/chart: {{ include "openops.chart" . }}
{{ include "openops.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openops.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openops.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component-specific labels
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.componentLabels" -}}
{{- $root := .root -}}
{{- $component := .component -}}
helm.sh/chart: {{ include "openops.chart" $root }}
app.kubernetes.io/name: {{ include "openops.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ $component }}
{{- if $root.Chart.AppVersion }}
app.kubernetes.io/version: {{ $root.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
{{- end }}

{{/*
Component-specific selector labels
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.componentSelectorLabels" -}}
{{- $root := .root -}}
{{- $component := .component -}}
app.kubernetes.io/name: {{ include "openops.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ $component }}
{{- end }}

{{/*
Redis connection parameters
*/}}
{{- define "openops.redisHost" -}}
{{- .Values.redis.name -}}
{{- end }}

{{- define "openops.redisPort" -}}
{{- .Values.redis.service.port | toString -}}
{{- end }}

{{- define "openops.redisUrl" -}}
{{- printf "redis://%s:%s/0" (include "openops.redisHost" .) (include "openops.redisPort" .) -}}
{{- end }}

{{/*
PostgreSQL connection parameters
*/}}
{{- define "openops.postgresHost" -}}
{{- .Values.postgres.name -}}
{{- end }}

{{- define "openops.postgresPort" -}}
{{- default (.Values.postgres.service.port | toString) -}}
{{- end }}

{{/*
Service URLs
*/}}
{{- define "openops.appServiceUrl" -}}
{{- printf "http://%s" .Values.app.name -}}
{{- end }}

{{- define "openops.engineServiceUrl" -}}
{{- printf "http://%s:3005" .Values.engine.name -}}
{{- end }}

{{- define "openops.tablesServiceUrl" -}}
{{- printf "http://%s" .Values.tables.name -}}
{{- end }}

{{- define "openops.analyticsServiceUrl" -}}
{{- printf "http://%s:8088" .Values.analytics.name -}}
{{- end }}

{{/*
Check if nginx ingress controller is being used
*/}}
{{- define "openops.isNginxIngress" -}}
{{- or (eq .Values.ingress.ingressClassName "nginx") (eq .Values.ingress.className "nginx") -}}
{{- end }}

{{/*
Secret name used to store sensitive environment variables.
*/}}
{{- define "openops.secretName" -}}
{{- $secretConfig := default (dict) .Values.secretEnv -}}
{{- $existing := default "" $secretConfig.existingSecret -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- printf "%s-env" (include "openops.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Determine if an environment variable name should be treated as a secret.
*/}}
{{- define "openops.isSecretKey" -}}
{{- $key := upper . -}}
{{- if or (contains "PASSWORD" $key) (contains "SECRET" $key) (contains "KEY" $key) -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Render a single environment variable, sourcing secrets from the shared secret when needed.
Expected dict: { "root": $, "key": "ENV", "value": "value" }
*/}}
{{- define "openops.envVar" -}}
{{- $root := .root -}}
{{- $key := .key -}}
{{- $value := .value -}}
{{- if eq (include "openops.isSecretKey" $key) "true" -}}
- name: {{ $key }}
  valueFrom:
    secretKeyRef:
      name: {{ include "openops.secretName" $root }}
      key: {{ $key }}
{{- else -}}
- name: {{ $key }}
  value: {{ tpl (tpl $value $root) $root | quote }}
{{- end -}}
{{- end }}

{{/*
Render environment variables from a map using openops.envVar.
Expected dict: { "root": $, "env": dict }
*/}}
{{- define "openops.renderEnv" -}}
{{- $root := .root -}}
{{- $env := .env -}}
{{- if $env }}
{{- range $k, $v := $env }}
{{ include "openops.envVar" (dict "root" $root "key" $k "value" $v) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Render deployment strategy
*/}}
{{- define "openops.deploymentStrategy" -}}
{{- if .Values.global.strategy }}
strategy:
  type: {{ .Values.global.strategy.type }}
  {{- if and (eq .Values.global.strategy.type "RollingUpdate") .Values.global.strategy.rollingUpdate }}
  rollingUpdate:
    maxSurge: {{ .Values.global.strategy.rollingUpdate.maxSurge }}
    maxUnavailable: {{ .Values.global.strategy.rollingUpdate.maxUnavailable }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Render topology spread constraints
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.topologySpreadConstraints" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- if and $root.Values.global.topologySpreadConstraints (hasKey $root.Values.global.topologySpreadConstraints "enabled") ($root.Values.global.topologySpreadConstraints.enabled) }}
topologySpreadConstraints:
  - maxSkew: {{ $root.Values.global.topologySpreadConstraints.maxSkew }}
    topologyKey: {{ $root.Values.global.topologySpreadConstraints.topologyKey }}
    whenUnsatisfiable: {{ $root.Values.global.topologySpreadConstraints.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        {{- include "openops.componentSelectorLabels" (dict "root" $root "component" $component) | nindent 8 }}
{{- end }}
{{- end }}

{{/*
Render affinity rules
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.affinity" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $affinity := $root.Values.global.affinity -}}
{{- if and $affinity $affinity.enabled }}
affinity:
  podAntiAffinity:
    {{- $podAntiAffinity := $affinity.podAntiAffinity -}}
    {{- if and $podAntiAffinity $podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution }}
    preferredDuringSchedulingIgnoredDuringExecution:
      {{- range $podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution }}
      - weight: {{ .weight }}
        podAffinityTerm:
          topologyKey: {{ .podAffinityTerm.topologyKey }}
          labelSelector:
            matchLabels:
              {{- include "openops.componentSelectorLabels" (dict "root" $root "component" $component) | nindent 14 }}
      {{- end }}
    {{- end }}
{{- end }}
{{- end }}

{{/*
Render priority class name
*/}}
{{- define "openops.priorityClassName" -}}
{{- if .Values.global.priorityClassName }}
priorityClassName: {{ .Values.global.priorityClassName }}
{{- end }}
{{- end }}

{{/*
Checksum of the secret data to trigger pod rollouts when sensitive data changes.
Only compute the checksum when this chart actually creates the secret, i.e., when
.Values.secretEnv.create is true and .Values.secretEnv.existingSecret is not set.
Returns empty string when using an external secret to avoid circular dependencies.
*/}}
{{- define "openops.secretChecksum" -}}
{{- if and .Values.secretEnv (default true .Values.secretEnv.create) (not .Values.secretEnv.existingSecret) -}}
{{- $root := . -}}
{{- $secretData := dict -}}
{{- if .Values.secretEnv.data -}}
{{- $data := dict -}}
{{- range $k, $v := .Values.secretEnv.data }}
{{- $_ := set $data $k (tpl (tpl $v $root) $root | b64enc) -}}
{{- end -}}
{{- $_ := set $secretData "data" $data -}}
{{- end -}}
{{- if .Values.secretEnv.stringData -}}
{{- $renderedStringData := dict -}}
{{- range $k, $v := .Values.secretEnv.stringData }}
{{- $_ := set $renderedStringData $k (tpl (tpl $v $root) $root) -}}
{{- end }}
{{- $_ := set $secretData "stringData" $renderedStringData -}}
{{- end -}}
{{- if $secretData -}}
{{- toYaml $secretData | sha256sum -}}
{{- end -}}
{{- end }}
{{- end }}

{{/*
Validate that required secrets are configured - ALWAYS ENFORCED
*/}}
{{- define "openops.validateSecrets" -}}
{{- $encKey := .Values.openopsEnv.OPS_ENCRYPTION_KEY -}}
{{- if not $encKey -}}
{{- fail "ERROR: OPS_ENCRYPTION_KEY is required. Generate with: openssl rand -hex 32" -}}
{{- end -}}
{{- if ne (len $encKey) 32 -}}
{{- fail "ERROR: OPS_ENCRYPTION_KEY must be exactly 32 hex characters" -}}
{{- end -}}
{{- if not .Values.openopsEnv.OPS_JWT_SECRET -}}
{{- fail "ERROR: OPS_JWT_SECRET is required. Generate with: openssl rand -hex 32" -}}
{{- end -}}
{{- if not .Values.openopsEnv.OPS_OPENOPS_ADMIN_PASSWORD -}}
{{- fail "ERROR: OPS_OPENOPS_ADMIN_PASSWORD is required. Use a strong password" -}}
{{- end -}}
{{- if not .Values.openopsEnv.OPS_POSTGRES_PASSWORD -}}
{{- fail "ERROR: OPS_POSTGRES_PASSWORD is required. Use a strong password" -}}
{{- end -}}
{{- if not .Values.openopsEnv.OPS_ANALYTICS_ADMIN_PASSWORD -}}
{{- fail "ERROR: OPS_ANALYTICS_ADMIN_PASSWORD is required. Use a strong password" -}}
{{- end -}}
{{- if not .Values.openopsEnv.ANALYTICS_POWERUSER_PASSWORD -}}
{{- fail "ERROR: ANALYTICS_POWERUSER_PASSWORD is required. Use a strong password" -}}
{{- end -}}
{{- end }}

{{/*
Validate production-ready configuration
*/}}
{{- define "openops.validateProduction" -}}
{{- $component := .component -}}
{{- $config := index .root.Values $component -}}
{{- if and $config.replicas (lt ($config.replicas | int) 2) -}}
{{- if not .root.Values.global.allowSingleReplica -}}
{{- fail (printf "ERROR: %s requires at least 2 replicas for high availability. Set global.allowSingleReplica=true to override for dev/test" $component) -}}
{{- end -}}
{{- end -}}
{{- if not $config.resources -}}
{{- fail (printf "ERROR: %s must have resource requests and limits defined" $component) -}}
{{- end -}}
{{- if not $config.resources.limits -}}
{{- fail (printf "ERROR: %s must have resource limits defined" $component) -}}
{{- end -}}
{{- end }}

{{/*
Service account name for a component
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.serviceAccountName" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $componentConfig := index $root.Values $component -}}
{{- if and $componentConfig.serviceAccount $componentConfig.serviceAccount.create -}}
{{- default (printf "%s-%s" (include "openops.fullname" $root) $component) $componentConfig.serviceAccount.name -}}
{{- else -}}
default
{{- end -}}
{{- end }}

{{/*
Image pull secrets
*/}}
{{- define "openops.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod security context
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.podSecurityContext" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $componentConfig := index $root.Values $component -}}
{{- if and $componentConfig.securityContext $componentConfig.securityContext.enabled }}
securityContext:
  runAsNonRoot: {{ $componentConfig.securityContext.runAsNonRoot }}
  runAsUser: {{ $componentConfig.securityContext.runAsUser }}
  fsGroup: {{ $componentConfig.securityContext.fsGroup }}
  {{- if $componentConfig.securityContext.seccompProfile }}
  seccompProfile:
    type: {{ $componentConfig.securityContext.seccompProfile.type }}
  {{- end }}
{{- else if and $root.Values.global.securityContext $root.Values.global.securityContext.enabled }}
securityContext:
  runAsNonRoot: {{ $root.Values.global.securityContext.runAsNonRoot }}
  runAsUser: {{ $root.Values.global.securityContext.runAsUser }}
  fsGroup: {{ $root.Values.global.securityContext.fsGroup }}
  {{- if $root.Values.global.securityContext.seccompProfile }}
  seccompProfile:
    type: {{ $root.Values.global.securityContext.seccompProfile.type }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Container security context
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.containerSecurityContext" -}}
{{- $root := .root -}}
{{- if and $root.Values.global.containerSecurityContext $root.Values.global.containerSecurityContext.enabled }}
securityContext:
  allowPrivilegeEscalation: {{ $root.Values.global.containerSecurityContext.allowPrivilegeEscalation }}
  readOnlyRootFilesystem: {{ $root.Values.global.containerSecurityContext.readOnlyRootFilesystem }}
  runAsNonRoot: {{ $root.Values.global.containerSecurityContext.runAsNonRoot }}
  runAsUser: {{ $root.Values.global.containerSecurityContext.runAsUser }}
  {{- if $root.Values.global.containerSecurityContext.capabilities }}
  capabilities:
    drop:
    {{- range $root.Values.global.containerSecurityContext.capabilities.drop }}
      - {{ . }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Termination grace period
*/}}
{{- define "openops.terminationGracePeriodSeconds" -}}
{{- if .Values.global.terminationGracePeriodSeconds }}
terminationGracePeriodSeconds: {{ .Values.global.terminationGracePeriodSeconds }}
{{- end }}
{{- end }}

{{/*
Node selector
*/}}
{{- define "openops.nodeSelector" -}}
{{- if .Values.global.nodeSelector }}
nodeSelector:
{{ toYaml .Values.global.nodeSelector | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Tolerations
*/}}
{{- define "openops.tolerations" -}}
{{- if .Values.global.tolerations }}
tolerations:
{{ toYaml .Values.global.tolerations | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Prometheus annotations
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.prometheusAnnotations" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $componentConfig := index $root.Values $component -}}
{{- if and $componentConfig.metrics $componentConfig.metrics.enabled }}
prometheus.io/scrape: "true"
prometheus.io/port: "{{ $componentConfig.metrics.port }}"
prometheus.io/path: "{{ $componentConfig.metrics.path }}"
{{- end }}
{{- end }}

{{/*
Lifecycle preStop hook for graceful shutdown
*/}}
{{- define "openops.lifecyclePreStop" -}}
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]
{{- end }}

{{/*
Startup probe for slow-starting containers
Expected dict: { "root": $, "component": "app", "path": "/health", "port": 80 }
*/}}
{{- define "openops.startupProbe" -}}
{{- $path := .path -}}
{{- $port := .port -}}
startupProbe:
  httpGet:
    path: {{ $path }}
    port: {{ $port }}
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 30
{{- end }}

{{/*
Init containers
Expected dict: { "root": $, "component": "app" }
*/}}
{{- define "openops.initContainers" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $componentConfig := index $root.Values $component -}}
{{- if $componentConfig.initContainers }}
initContainers:
{{ toYaml $componentConfig.initContainers | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Component-specific affinity (for stateful components)
Expected dict: { "root": $, "component": "postgres" }
*/}}
{{- define "openops.componentAffinity" -}}
{{- $root := .root -}}
{{- $component := .component -}}
{{- $componentConfig := index $root.Values $component -}}
{{- if and $componentConfig.affinity $componentConfig.affinity.enabled }}
affinity:
  podAntiAffinity:
    {{- $podAntiAffinity := $componentConfig.affinity.podAntiAffinity -}}
    {{- if $podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution }}
    preferredDuringSchedulingIgnoredDuringExecution:
    {{- range $podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution }}
      - weight: {{ .weight }}
        podAffinityTerm:
          topologyKey: {{ .podAffinityTerm.topologyKey }}
          labelSelector:
            matchExpressions:
            {{- range .podAffinityTerm.labelSelector.matchExpressions }}
              - key: {{ .key }}
                operator: {{ .operator }}
                values:
                {{- range .values }}
                  - {{ . }}
                {{- end }}
            {{- end }}
    {{- end }}
    {{- end }}
{{- end }}
{{- end }}
