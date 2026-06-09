{{/* Name helpers + standard labels for the generic itOrchestra service chart. */}}

{{- define "itorchestra-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "itorchestra-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "itorchestra-service.labels" -}}
app.kubernetes.io/name: {{ include "itorchestra-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app: {{ include "itorchestra-service.fullname" . }}
{{- end -}}

{{- define "itorchestra-service.selectorLabels" -}}
app: {{ include "itorchestra-service.fullname" . }}
{{- end -}}
