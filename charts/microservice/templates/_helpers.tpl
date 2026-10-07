{{/* Names and labels come from the common library chart (charts/common). */}}
{{- define "microservice.name" -}}{{ include "common.name" . }}{{- end -}}
{{- define "microservice.labels" -}}{{ include "common.labels" . }}{{- end -}}
{{- define "microservice.selectorLabels" -}}{{ include "common.selectorLabels" . }}{{- end -}}

{{/* microservice.path PATH: PATH under the service's context path. */}}
{{- define "microservice.path" -}}{{ .root.Values.contextPath }}{{ .path }}{{- end -}}
