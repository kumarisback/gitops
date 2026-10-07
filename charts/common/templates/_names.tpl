{{/*
common.name: the application's name. Defaults to the release name, so
`helm install order-service ./microservice` makes resources named
order-service; nameOverride replaces it. Truncated to 63 characters, the
limit for Kubernetes names and label values.
*/}}
{{- define "common.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* common.chart: chart name and version, for the helm.sh/chart label. */}}
{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
