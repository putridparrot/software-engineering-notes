{{/*
Chart name, overridable with nameOverride.
*/}}
{{- define "visits.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Prefix for every resource name. Uses the release name, so two releases
(e.g. "visits-dev" and "visits-test") can live in the same namespace.
*/}}
{{- define "visits.fullname" -}}
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
Common labels for every resource (the recommended app.kubernetes.io set).
*/}}
{{- define "visits.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for one component - these must never change after install.
Usage: include "visits.selectorLabels" (dict "root" . "component" "api")
*/}}
{{- define "visits.selectorLabels" -}}
app.kubernetes.io/name: {{ include "visits.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Full image reference, adding the registry prefix and defaulting the tag to appVersion.
Usage: include "visits.image" (dict "root" . "image" .Values.api.image)
*/}}
{{- define "visits.image" -}}
{{- $tag := .image.tag | default .root.Chart.AppVersion -}}
{{- if .root.Values.imageRegistry -}}
{{ .root.Values.imageRegistry }}/{{ .image.repository }}:{{ $tag }}
{{- else -}}
{{ .image.repository }}:{{ $tag }}
{{- end -}}
{{- end }}

{{/*
In-cluster DNS name of the Redis service.
*/}}
{{- define "visits.redisHost" -}}
{{ include "visits.fullname" . }}-redis
{{- end }}
