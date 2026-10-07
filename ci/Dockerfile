# Toolbox for scripts/validate.sh and the Jenkins pipeline. Every tool is
# pinned to the version this repo deploys (keep in step with the charts in
# addons/applications), and every download is checked against a SHA-256
# recorded here rather than fetched at build time. Renovate only bumps the
# base image; to bump a tool, change its *_VERSION and both *_SHA256_* args
# (from the release's published checksums), then run validate.sh.
#
#   docker build -t gitops-ci ci/
#   docker run --rm -v "$PWD:/repo" -w /repo gitops-ci ./scripts/validate.sh
FROM debian:bookworm-slim

ARG TARGETARCH

ARG KUBECTL_VERSION=1.33.1
ARG KUSTOMIZE_VERSION=5.6.0
# Helm 3, the major version ArgoCD renders charts with.
ARG HELM_VERSION=3.17.3
ARG KUBECONFORM_VERSION=0.6.7
# Prometheus and Alertmanager in kube-prometheus-stack 61.3.0.
ARG PROMETHEUS_VERSION=2.53.0
ARG ALERTMANAGER_VERSION=0.27.0
# appVersion of alloy 1.11.1, opentelemetry-collector 0.173.1 and loki 6.6.2.
ARG ALLOY_VERSION=1.18.1
ARG OTELCOL_VERSION=0.160.0
ARG LOKI_VERSION=3.0.0
# helm unittest, for charts/*/tests.
ARG HELM_UNITTEST_VERSION=1.2.1

ARG KUBECTL_SHA256_amd64=5de4e9f2266738fd112b721265a0c1cd7f4e5208b670f811861f699474a100a3
ARG KUBECTL_SHA256_arm64=d595d1a26b7444e0beb122e25750ee4524e74414bbde070b672b423139295ce6
ARG KUSTOMIZE_SHA256_amd64=54e4031ddc4e7fc59e408da29e7c646e8e57b8088c51b84b3df0864f47b5148f
ARG KUSTOMIZE_SHA256_arm64=ad8ab62d4f6d59a8afda0eec4ba2e5cd2f86bf1afeea4b78d06daac945eb0660
ARG HELM_SHA256_amd64=ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd
ARG HELM_SHA256_arm64=7944e3defd386c76fd92d9e6fec5c2d65a323f6fadc19bfb5e704e3eee10348e
ARG KUBECONFORM_SHA256_amd64=95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73
ARG KUBECONFORM_SHA256_arm64=dc82f79bb03c5479b1ae5fd4af221e4b5a3111f62bf01a2795d9c5c20fa96644
ARG PROMETHEUS_SHA256_amd64=d9900a11e3c89261e6416e3c9989858bad7b206af8b6838dfe9a5392d8ddc60d
ARG PROMETHEUS_SHA256_arm64=f3fb3c12db28155a791eba57f293c899ad753677a5aa8c327a80483b23ce98c6
ARG ALERTMANAGER_SHA256_amd64=23c3f5a3c73de91dbaec419f3c492bef636deb02680808e5d842e6553aa16074
ARG ALERTMANAGER_SHA256_arm64=a754304b682cec61f4bd5cfc029b451a30134554b3a2f21a9c487e12814ff8f3
ARG ALLOY_SHA256_amd64=fac853cbc3983a50a2368f9a685b31f74392ae86dd6155461b11a911c07b483c
ARG ALLOY_SHA256_arm64=499446cfe22514d6c9f00af953d98162526ea818e84c4e452f8fddbbfa8676d6
ARG OTELCOL_SHA256_amd64=7bb60c584c241c86261c2b8697cd3725dd8c56691f5ad5d98454eaa005b47b0c
ARG OTELCOL_SHA256_arm64=bff414e6a287309dfd0c51350c1e13c96c4ab807127b4320bd684f605e781326
ARG LOKI_SHA256_amd64=6f6cb5cfb1ea9c00794b3928a7af0e448930b2854938f3a18012c707158c4f7a
ARG LOKI_SHA256_arm64=2f7b406fea48eccd7a6e08187d7dedb77cff38f4f04e271982a7185d3a68225c

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq ruby unzip \
 && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eux; \
    arch="${TARGETARCH:-amd64}"; \
    sha() { local v="$1_SHA256_${arch}"; echo "${!v}"; }; \
    fetch() { curl -fsSL --retry 3 -o "$2" "$1"; echo "$3  $2" | sha256sum -c -; }; \
    cd /tmp; \
    fetch "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" kubectl "$(sha KUBECTL)"; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${arch}.tar.gz" kustomize.tgz "$(sha KUSTOMIZE)"; \
    tar -xzf kustomize.tgz -C /usr/local/bin kustomize; \
    fetch "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" helm.tgz "$(sha HELM)"; \
    tar -xzf helm.tgz --strip-components=1 -C /usr/local/bin "linux-${arch}/helm"; \
    fetch "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${arch}.tar.gz" kubeconform.tgz "$(sha KUBECONFORM)"; \
    tar -xzf kubeconform.tgz -C /usr/local/bin kubeconform; \
    fetch "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${arch}.tar.gz" prometheus.tgz "$(sha PROMETHEUS)"; \
    tar -xzf prometheus.tgz --strip-components=1 -C /usr/local/bin "prometheus-${PROMETHEUS_VERSION}.linux-${arch}/promtool"; \
    fetch "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-${arch}.tar.gz" alertmanager.tgz "$(sha ALERTMANAGER)"; \
    tar -xzf alertmanager.tgz --strip-components=1 -C /usr/local/bin "alertmanager-${ALERTMANAGER_VERSION}.linux-${arch}/amtool"; \
    fetch "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-linux-${arch}.zip" alloy.zip "$(sha ALLOY)"; \
    unzip -q alloy.zip && install -m 0755 "alloy-linux-${arch}" /usr/local/bin/alloy; \
    fetch "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_${arch}.tar.gz" otelcol.tgz "$(sha OTELCOL)"; \
    tar -xzf otelcol.tgz -C /usr/local/bin otelcol-contrib; \
    fetch "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${arch}.zip" loki.zip "$(sha LOKI)"; \
    unzip -q loki.zip && install -m 0755 "loki-linux-${arch}" /usr/local/bin/loki; \
    rm -rf /tmp/*; \
    for t in kubectl kustomize helm kubeconform promtool amtool alloy otelcol-contrib loki; do command -v "$t"; done

# helm unittest, in a fixed plugin directory (Jenkins' HELM_DATA_HOME below
# is per build). Its install hook downloads the binary and checks it against
# the release's published SHA-256.
ENV HELM_PLUGINS=/opt/helm/plugins
RUN mkdir -p "${HELM_PLUGINS}" \
 && helm plugin install https://github.com/helm-unittest/helm-unittest.git --version "v${HELM_UNITTEST_VERSION}" \
 && helm unittest --help > /dev/null

# Jenkins runs the container as its own uid with no writable home; keep
# Helm's and kubeconform's caches under /tmp.
ENV HELM_CACHE_HOME=/tmp/helm/cache \
    HELM_CONFIG_HOME=/tmp/helm/config \
    HELM_DATA_HOME=/tmp/helm/data \
    XDG_CACHE_HOME=/tmp/.cache
