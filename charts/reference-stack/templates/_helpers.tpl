{{/*
Base name for all resources in this release.
*/}}
{{- define "reference-stack.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, prefixed with the release name unless the release
name already contains the chart name.
*/}}
{{- define "reference-stack.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Chart name and version, used in the chart label.
*/}}
{{- define "reference-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every resource.
*/}}
{{- define "reference-stack.labels" -}}
helm.sh/chart: {{ include "reference-stack.chart" . }}
{{ include "reference-stack.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels, shared by Deployments/StatefulSets and their Services.
*/}}
{{- define "reference-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "reference-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Component-specific selector labels, e.g. app / postgres / redis / migration.
Call with (dict "component" "app" "context" $) — "context" must be the root
template context ($), not "." from inside a nested scope.
*/}}
{{- define "reference-stack.componentSelectorLabels" -}}
{{ include "reference-stack.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
ServiceAccount name to use.
*/}}
{{- define "reference-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "reference-stack.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Postgres connection host, derived from the release name — used by the app
Deployment and the migration Job so both stay in sync with the Service name.
*/}}
{{- define "reference-stack.postgresHost" -}}
{{- printf "%s-postgres" (include "reference-stack.fullname" .) -}}
{{- end -}}

{{/*
Redis connection host.
*/}}
{{- define "reference-stack.redisHost" -}}
{{- printf "%s-redis" (include "reference-stack.fullname" .) -}}
{{- end -}}
