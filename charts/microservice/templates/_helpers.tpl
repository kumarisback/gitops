{{/* Names and labels come from the common library chart (charts/common). */}}
{{- define "microservice.name" -}}{{ include "common.name" . }}{{- end -}}
{{- define "microservice.labels" -}}{{ include "common.labels" . }}{{- end -}}
{{- define "microservice.selectorLabels" -}}{{ include "common.selectorLabels" . }}{{- end -}}

{{/* microservice.path PATH: PATH under the service's context path. */}}
{{- define "microservice.path" -}}{{ .root.Values.contextPath }}{{ .path }}{{- end -}}

{{/*
The Kafka connection, and the service's event publishing on
(app.events.enabled). Two kinds:

- Strimzi (roadmap step 12): from the Secret a KafkaAccess resource creates
  (apps/components/kafka-clients): bootstrap servers, protocol, and the TLS
  client certificate, key and cluster CA as a Spring SSL bundle named "kafka"
  (PEM content in the environment; Spring reads it without files).
- Amazon MSK (step 14), with kafka.msk.bootstrapServers: SASL over TLS with
  IAM. The service signs in with its IRSA role (serviceAccount.annotations)
  through AWS's login module, which the images carry; MSK's certificates
  are publicly trusted, so no SSL bundle.
*/}}
{{- define "microservice.kafkaEnv" -}}
- name: APP_EVENTS_ENABLED
  value: "true"
{{- with .Values.kafka.msk.bootstrapServers }}
{{- if and $.Values.serviceAccount.create (not (index $.Values.serviceAccount.annotations "eks.amazonaws.com/role-arn")) }}
{{- fail "kafka.msk needs the service's IRSA role in serviceAccount.annotations (eks.amazonaws.com/role-arn)" }}
{{- end }}
- name: SPRING_KAFKA_BOOTSTRAP_SERVERS
  value: {{ . | quote }}
- name: SPRING_KAFKA_SECURITY_PROTOCOL
  value: SASL_SSL
- name: SPRING_KAFKA_PROPERTIES_SASL_MECHANISM
  value: AWS_MSK_IAM
- name: SPRING_KAFKA_PROPERTIES_SASL_JAAS_CONFIG
  value: software.amazon.msk.auth.iam.IAMLoginModule required;
- name: SPRING_KAFKA_PROPERTIES_SASL_CLIENT_CALLBACK_HANDLER_CLASS
  value: software.amazon.msk.auth.iam.IAMClientCallbackHandler
{{- else }}
{{- $secret := required "kafka.accessSecret is required when kafka.enabled" $.Values.kafka.accessSecret }}
- name: SPRING_KAFKA_SSL_BUNDLE
  value: kafka
{{- range $env, $key := dict "SPRING_KAFKA_BOOTSTRAP_SERVERS" "bootstrap.servers" "SPRING_KAFKA_SECURITY_PROTOCOL" "security.protocol" "SPRING_SSL_BUNDLE_PEM_KAFKA_KEYSTORE_CERTIFICATE" "ssl.keystore.crt" "SPRING_SSL_BUNDLE_PEM_KAFKA_KEYSTORE_PRIVATEKEY" "ssl.keystore.key" "SPRING_SSL_BUNDLE_PEM_KAFKA_TRUSTSTORE_CERTIFICATE" "ssl.truststore.crt" }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $key }}
{{- end }}
{{- end }}
{{- end -}}
