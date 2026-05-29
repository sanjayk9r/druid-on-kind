{{- define "garage.name" -}}
{{- .Values.fullnameOverride | default "garage" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "garage.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "garage.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
