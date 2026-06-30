{{- define "kafka.name" -}}
{{- .Values.fullnameOverride | default "kafka" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kafka.serviceName" -}}
{{- .Values.service.name | default (include "kafka.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kafka.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "kafka.advertisedListeners" -}}
PLAINTEXT://{{ include "kafka.serviceName" . }}.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.service.port }}
{{- end -}}
