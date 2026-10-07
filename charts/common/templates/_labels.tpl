{{/*
common.labels: the recommended Kubernetes labels
(https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)
plus `app`, which this repo's Services, ServiceMonitors, alerts and the
OpenTelemetry service name already key on.
*/}}
{{- define "common.labels" -}}
{{ include "common.selectorLabels" . }}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: microservices
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "common.chart" . }}
{{- with .Values.image.tag }}
app.kubernetes.io/version: {{ . | trunc 63 | quote }}
{{- end }}
{{- end -}}

{{/*
common.selectorLabels: the labels a Deployment selects its pods by. Only
`app`: a Deployment's selector can't be changed after creation, and the
Kustomize-deployed version of each service already selects on app alone.
*/}}
{{- define "common.selectorLabels" -}}
app: {{ include "common.name" . }}
{{- end -}}
