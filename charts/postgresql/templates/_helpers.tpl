{{- define "postgresql.name" -}}
{{- .Values.fullnameOverride | default "postgres" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
