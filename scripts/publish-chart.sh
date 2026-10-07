#!/usr/bin/env bash
# Publishes one of this repo's charts to ECR as an OCI artifact:
#   oci://<registry>/charts/<name>:<version from Chart.yaml>
# Run by Jenkins on main (Jenkinsfile, "Publish Chart"). Install it from ECR
# with:  helm install order-service oci://<registry>/charts/microservice --version <v> -f values.yaml
#
# ECR tags are immutable, so each version is published once. If it already
# exists with the same contents there is nothing to do; if the contents
# differ, the chart changed without a version bump and this fails.
#
# ECR login: with ECR_TOKEN_ON_STDIN=1 the script reads an ECR login token
# (aws ecr get-login-password: push/pull only, valid 12 hours) from stdin.
# That's how Jenkins runs it: the token is fetched on the host and piped in,
# so the container never sees the instance role's credentials. Without it,
# Helm uses whatever registry login you already have (helm registry login).
#
#   ./scripts/publish-chart.sh charts/microservice
#   aws ecr get-login-password | ECR_TOKEN_ON_STDIN=1 ./scripts/publish-chart.sh charts/microservice
set -euo pipefail

CHART_DIR="${1:?usage: $0 charts/<chart>}"
REGISTRY="${ECR_REGISTRY:-602367507570.dkr.ecr.us-east-1.amazonaws.com}"
name="$(sed -n 's/^name: *//p' "${CHART_DIR}/Chart.yaml")"
version="$(sed -n 's/^version: *//p' "${CHART_DIR}/Chart.yaml")"
ref="oci://${REGISTRY}/charts/${name}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

if [ "${ECR_TOKEN_ON_STDIN:-0}" = 1 ]; then
  helm registry login "${REGISTRY}" --username AWS --password-stdin > /dev/null
fi

# unpack TGZ DIR: the chart and its bundled dependency charts, as plain files,
# so archive timestamps don't count as differences.
unpack() {
  mkdir -p "$2"
  tar -xzf "$1" -C "$2"
  find "$2" -path '*/charts/*.tgz' | while read -r dep; do
    tar -xzf "${dep}" -C "$(dirname "${dep}")" && rm "${dep}"
  done
}

helm dependency build "${CHART_DIR}" > /dev/null
helm package "${CHART_DIR}" -d "${work}/new" > /dev/null
package="${work}/new/${name}-${version}.tgz"

if helm pull "${ref}" --version "${version}" -d "${work}/published" > /dev/null 2>&1; then
  unpack "${package}" "${work}/a"
  unpack "${work}/published/${name}-${version}.tgz" "${work}/b"
  if diff -r "${work}/a" "${work}/b" > /dev/null; then
    echo "${name} ${version} is already published with these contents."
    exit 0
  fi
  echo "❌ ${name} ${version} is already published with different contents: bump version in ${CHART_DIR}/Chart.yaml." >&2
  diff -r "${work}/a" "${work}/b" >&2 || true
  exit 1
fi

helm push "${package}" "oci://${REGISTRY}/charts"
echo "Published ${ref}:${version}"
