{{/* Names and labels come from the common library chart (charts/common). */}}
{{- define "microservice.name" -}}{{ include "common.name" . }}{{- end -}}
{{- define "microservice.labels" -}}{{ include "common.labels" . }}{{- end -}}
{{- define "microservice.selectorLabels" -}}{{ include "common.selectorLabels" . }}{{- end -}}

{{/* microservice.path PATH: PATH under the service's context path. */}}
{{- define "microservice.path" -}}{{ .root.Values.contextPath }}{{ .path }}{{- end -}}

{{/*
The Kafka connection from the Secret a KafkaAccess resource creates
(apps/components/kafka-clients): bootstrap servers, protocol, and the TLS
client certificate, key and cluster CA as a Spring SSL bundle named "kafka"
(PEM content in the environment; Spring reads it without files). Also turns
the service's event publishing on (app.events.enabled).
*/}}
{{- define "microservice.kafkaEnv" -}}
{{- $secret := required "kafka.accessSecret is required when kafka.enabled" .Values.kafka.accessSecret -}}
- name: APP_EVENTS_ENABLED
  value: "true"
- name: SPRING_KAFKA_SSL_BUNDLE
  value: kafka
{{- range $env, $key := dict "SPRING_KAFKA_BOOTSTRAP_SERVERS" "bootstrap.servers" "SPRING_KAFKA_SECURITY_PROTOCOL" "security.protocol" "SPRING_SSL_BUNDLE_PEM_KAFKA_KEYSTORE_CERTIFICATE" "ssl.keystore.crt" "SPRING_SSL_BUNDLE_PEM_KAFKA_KEYSTORE_PRIVATEKEY" "ssl.keystore.key" "SPRING_SSL_BUNDLE_PEM_KAFKA_TRUSTSTORE_CERTIFICATE" "ssl.truststore.crt" }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $key }}
{{- end }}
{{- end -}}
