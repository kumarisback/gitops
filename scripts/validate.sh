#!/usr/bin/env bash
# Validates everything this repo deploys, using the same parsers the
# services themselves use for their config. Jenkins runs it on every build
# (see Jenkinsfile; ci/Dockerfile pins the tool versions). Run it before
# pushing:
#
#   ./scripts/validate.sh
#
# Checks, for every environment (local, dev, staging, prod):
#   - every kustomize overlay builds, and the output passes kubeconform
#     (Kubernetes + CRD schemas, strict)
#   - every Helm add-on renders with its layered values and passes kubeconform
#   - this repo's own charts (charts/) lint with every environment's values,
#     and their unit tests (charts/*/tests, helm-unittest) pass
#   - Alloy, OpenTelemetry Collector, Loki and Alertmanager accept the
#     config they will actually be given (alloy validate, otelcol validate,
#     loki -verify-config, amtool check-config)
#   - every PrometheusRule passes promtool check rules, and the rule unit
#     tests in tests/prometheus pass
#   - every Grafana dashboard ConfigMap holds valid JSON
#   - the Alloy log pipeline (redaction, multiline, log_type labels) turns
#     the sample lines in tests/alloy into the expected entries
#   - the lab scripts parse
#
# Rendered output and logs are kept in .validate/ (git-ignored); charts and
# schemas are cached in ~/.cache/gitops-validate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/.validate"
# Downloaded charts and JSON schemas survive between runs; set
# VALIDATE_CACHE to move them.
CACHE="${VALIDATE_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/gitops-validate}"
KUBE_VERSION="${KUBE_VERSION:-1.33.0}"
ENVS=(local dev staging prod)
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

cd "${REPO_ROOT}"
rm -rf "${OUT}"
mkdir -p "${OUT}"/{kustomize,helm,configs,rules,logs} "${CACHE}"/{charts,kubeconform}

missing=()
for tool in kubectl helm kubeconform promtool amtool alloy otelcol-contrib loki ruby; do
  command -v "${tool}" > /dev/null 2>&1 || missing+=("${tool}")
done
helm unittest --help > /dev/null 2>&1 || missing+=("helm-unittest plugin")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "❌ Missing tools: ${missing[*]} (ci/Dockerfile installs all of them)"
  exit 2
fi

FAILED=()
CHECKS=0

# check NAME COMMAND...: run COMMAND, log its output, record pass/fail.
check() {
  local name="$1"; shift
  local log="${OUT}/logs/$(printf '%s' "${name}" | tr -c 'A-Za-z0-9._-' '_').log"
  CHECKS=$((CHECKS + 1))
  if "$@" < /dev/null > "${log}" 2>&1; then
    printf '  ✓ %s\n' "${name}"
  else
    printf '  ✗ %s\n' "${name}"
    tail -n 25 "${log}" | sed 's/^/      /'
    FAILED+=("${name}")
  fi
}

kubeconform_file() {
  # CRD definitions themselves come from upstream charts and have no schema
  # to check against; the custom resources using them are still validated.
  kubeconform -strict -summary -kubernetes-version "${KUBE_VERSION}" \
    -skip CustomResourceDefinition -cache "${CACHE}/kubeconform" \
    -schema-location default -schema-location "${CRD_SCHEMAS}" "$1"
}

render_kustomize() {  # SRC DEST
  kubectl kustomize --load-restrictor LoadRestrictionsNone "$1" > "$2"
}

# --- 1. kustomize overlays -------------------------------------------------
echo "Kustomize overlays"
KUSTOMIZE_DIRS=(platform platform/karpenter/dev)
for env in "${ENVS[@]}"; do KUSTOMIZE_DIRS+=("apps/${env}" "observability/${env}" "bootstrap/envs/${env}"); done
for dir in "${KUSTOMIZE_DIRS[@]}"; do
  dest="${OUT}/kustomize/$(echo "${dir}" | tr '/' '_').yaml"
  check "build ${dir}" render_kustomize "${dir}" "${dest}"
  [ -s "${dest}" ] && check "schema ${dir}" kubeconform_file "${dest}"
done

# --- 2. Helm add-ons -------------------------------------------------------
pull_chart() {  # CHART REPO VERSION -> prints the chart directory
  local dir="${CACHE}/charts/$1-$3"
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
    case "$2" in
      oci://*/"$1") helm pull "$2" --version "$3" --untar --untardir "${dir}" > /dev/null || return 1 ;;
      oci://*) helm pull "$2/$1" --version "$3" --untar --untardir "${dir}" > /dev/null || return 1 ;;
      http*) helm pull "$1" --repo "$2" --version "$3" --untar --untardir "${dir}" > /dev/null || return 1 ;;
      # ArgoCD's OCI form: registry/path without a scheme.
      *) helm pull "oci://$2/$1" --version "$3" --untar --untardir "${dir}" > /dev/null || return 1 ;;
    esac
  fi
  echo "${dir}/$1"
}

render_release() {  # JSON DEST
  local json="$1" dest="$2" name chart repo version ns dir
  name=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["name"]' "${json}")
  chart=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["chart"]' "${json}")
  repo=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["repo"]' "${json}")
  version=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["version"]' "${json}")
  ns=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["namespace"]' "${json}")
  if [ "$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["local"] == true' "${json}")" = true ]; then
    # A chart from this repo: its file:// dependencies come from Chart.lock.
    dir="${chart}"
    helm dependency build "${dir}" > /dev/null || return 1
  else
    dir=$(pull_chart "${chart}" "${repo}" "${version}") || return 1
  fi
  # Inline values (Applications that still embed them) go first, then the
  # value files in order, the same precedence ArgoCD uses.
  local inline="${dest%.yaml}.inline-values.yaml"
  ruby -rjson -e 'print JSON.parse(ARGV[0])["inline_values"].to_s' "${json}" > "${inline}"
  local args=(-f "${inline}")
  while IFS= read -r f; do args+=(-f "${f}"); done < <(ruby -rjson -e 'JSON.parse(ARGV[0])["value_files"].each { |f| puts f }' "${json}")
  helm template "${name}" "${dir}" -n "${ns}" --kube-version "${KUBE_VERSION}" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PrometheusRule --api-versions policy/v1 \
    "${args[@]}" > "${dest}"
}

extract() {  # ARGS... DEST: run manifest_tool with stdout to DEST
  local dest="${!#}"
  ruby scripts/lib/manifest_tool.rb "${@:1:$#-1}" > "${dest}"
}

alloy_check()  { extract configmap "$1" config.alloy "$2" && alloy validate "$2"; }
# The collector config reads ${env:...}; give it the literal env vars the
# chart puts on the container (MY_POD_IP comes from the downward API).
otelcol_check() {
  extract configmap "$1" relay "$2" || return 1
  local vars=(MY_POD_IP=127.0.0.1)
  while IFS= read -r kv; do [ -n "${kv}" ] && vars+=("${kv}"); done < <(ruby scripts/lib/manifest_tool.rb env "$1")
  env "${vars[@]}" otelcol-contrib validate --config="file:$2"
}
loki_check()   { extract configmap "$1" config.yaml '^loki$' "$2" && loki -verify-config -config.expand-env=true -config.file="$2"; }
am_check()     { extract secret "$1" alertmanager.yaml '^alertmanager-' "$2" && amtool check-config "$2"; }

for env in "${ENVS[@]}"; do
  echo "Helm add-ons (${env})"
  if ! ruby scripts/lib/addon_releases.rb "bootstrap/envs/${env}" > "${OUT}/releases-${env}.jsonl" 2> "${OUT}/logs/releases-${env}.log"; then
    printf '  ✗ resolve releases\n'; sed 's/^/      /' "${OUT}/logs/releases-${env}.log"; FAILED+=("resolve releases ${env}"); continue
  fi
  while IFS= read -r rel; do
    name=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["name"]' "${rel}")
    chart=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["chart"]' "${rel}")
    dest="${OUT}/helm/${env}-${name}.yaml"
    check "${env}/${name}: helm template" render_release "${rel}" "${dest}"
    [ -s "${dest}" ] || continue
    check "${env}/${name}: schema" kubeconform_file "${dest}"
    cfg="${OUT}/configs/${env}-${name}"
    case "${chart}" in
      alloy) check "${env}/${name}: alloy validate" alloy_check "${dest}" "${cfg}.alloy" ;;
      opentelemetry-collector) check "${env}/${name}: otelcol validate" otelcol_check "${dest}" "${cfg}.yaml" ;;
      loki) check "${env}/${name}: loki -verify-config" loki_check "${dest}" "${cfg}.yaml" ;;
      kube-prometheus-stack) check "${env}/${name}: amtool check-config" am_check "${dest}" "${cfg}.yaml" ;;
    esac
  done < "${OUT}/releases-${env}.jsonl"
done

# This repo's own charts (charts/): lint, and the unit tests in
# charts/<chart>/tests (helm-unittest). The services' rendered releases are
# schema-checked with the add-ons above.
echo "Charts"
for chart in charts/*/; do
  name=$(basename "${chart}")
  check "${name}: helm dependency build" helm dependency build "${chart}"
  if [ "$(sed -n 's/^type: *//p' "${chart}Chart.yaml")" = library ]; then
    check "${name}: helm lint" helm lint "${chart}"
  else
    # An application chart needs real values to render (an image tag, an
    # environment): lint it with every values file that deploys it.
    for values in apps/*/*.values.yaml; do
      env=$(basename "$(dirname "${values}")")
      check "${name}: helm lint (${env}/$(basename "${values}"))" helm lint "${chart}" -f "${values}"
    done
  fi
  [ -d "${chart}tests" ] && check "${name}: helm unittest" helm unittest "${chart}"
done

# The lab's ingress controller is installed by start-lab.sh, not ArgoCD:
# render it with the same chart version (its values schema is strict).
echo "Lab ingress controller"
traefik_check() {
  local version dir
  version=$(sed -n 's/^TRAEFIK_CHART_VERSION="\(.*\)"$/\1/p' scripts/start-lab.sh)
  dir=$(pull_chart traefik https://traefik.github.io/charts "${version}") || return 1
  helm template traefik "${dir}" -n traefik --kube-version "${KUBE_VERSION}" \
    -f local-setup/traefik-values.yaml > "${OUT}/helm/local-traefik.yaml" && kubeconform_file "${OUT}/helm/local-traefik.yaml"
}
check "local/traefik: helm template + schema" traefik_check

# --- 3. Prometheus rules and Grafana dashboards ----------------------------
echo "Prometheus rules"
for f in "${OUT}"/kustomize/*.yaml "${OUT}"/helm/*.yaml; do
  [ -s "${f}" ] && ruby scripts/lib/manifest_tool.rb rules "${f}" "${OUT}/rules" > /dev/null
done
rule_files=("${OUT}"/rules/*.yaml)
if [ -e "${rule_files[0]}" ]; then
  check "promtool check rules (${#rule_files[@]} PrometheusRules)" promtool check rules "${rule_files[@]}"
fi
# The unit tests load this repo's rules from .validate/rules/observability/
# <PrometheusRule name>.yaml (see tests/prometheus/*.yaml).
mkdir -p "${OUT}/rules/observability"
ruby scripts/lib/manifest_tool.rb rules-by-name "${OUT}/kustomize/observability_local.yaml" "${OUT}/rules/observability"
tests=(tests/prometheus/*.yaml)
if [ -e "${tests[0]}" ]; then
  check "promtool test rules (${#tests[@]} files)" promtool test rules "${tests[@]}"
fi

echo "Grafana dashboards"
for f in "${OUT}"/kustomize/*.yaml; do
  [ -s "${f}" ] || continue
  if grep -q grafana_dashboard "${f}"; then
    check "dashboards in $(basename "${f}" .yaml)" ruby scripts/lib/manifest_tool.rb dashboards "${f}"
  fi
done

# --- 4. log pipeline -------------------------------------------------------
# alloy validate only checks syntax; this runs the real loki.process stages
# on sample lines (tests/alloy/pipeline_cases.yaml) and checks the output.
echo "Log pipeline"
check "alloy pipeline cases" ruby tests/alloy/pipeline_test.rb

# --- 5. lab scripts --------------------------------------------------------
echo "Scripts"
for f in scripts/*.sh; do check "bash -n ${f}" bash -n "${f}"; done
for f in scripts/*.rb scripts/lib/*.rb; do check "ruby -c ${f}" ruby -c "${f}"; done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "✅ ${CHECKS} checks passed."
else
  echo "❌ ${#FAILED[@]} of ${CHECKS} checks failed:"
  printf '   - %s\n' "${FAILED[@]}"
  exit 1
fi
