#!/usr/bin/env ruby
# Deploys everything root-app-local would normally have ArgoCD sync for the
# local (KinD) environment, directly via helm/kubectl - bypassing ArgoCD's
# own reconcile loop.
#
# Why: on this machine, ArgoCD's repo-server intermittently (and sometimes
# consistently) fails to fetch from github.com and the Helm chart repos,
# almost certainly due to corporate network traffic inspection (Zscaler +
# Cisco AnyConnect are active) adding latency/unreliability that Podman's
# VM networking doesn't smooth over the way Docker Desktop's does. This
# script reads the exact same Application manifests ArgoCD would
# (bootstrap/envs/local/*.yaml) so chart/version/values/namespace stay in
# sync with what's committed - it's a direct-apply mirror of that intent,
# not a separate source of truth. ArgoCD is left running for its UI/history;
# this just doesn't depend on it actually reconciling.
#
# Usage: ./scripts/sync-local-stack.rb
require 'yaml'
require 'tmpdir'
require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
LOCAL_ENV_DIR = File.join(REPO_ROOT, 'bootstrap/envs/local')

# Order matters: prometheus-stack installs the Prometheus Operator's CRDs
# (ServiceMonitor etc.), which otel-collector and alloy's charts create
# instances of (serviceMonitor.enabled: true in both) - it must go first or
# those two fail with "no matches for kind ServiceMonitor". Everything else
# is order-independent (retries on its own regardless).
HELM_CHART_APPS = %w[
  prometheus-stack.yaml
  metrics-server.yaml
  loki.yaml
  tempo.yaml
  otel-collector.yaml
  alloy.yaml
]

def run(cmd)
  puts "+ #{cmd}"
  system(cmd)
end

def sync_helm_app(file, failures)
  path = File.join(LOCAL_ENV_DIR, file)
  doc = YAML.load_file(path)
  spec = doc['spec']
  name = doc['metadata']['name']
  chart = spec['source']['chart']
  repo_url = spec['source']['repoURL']
  version = spec['source']['targetRevision']
  namespace = spec['destination']['namespace']
  values = spec.dig('source', 'helm', 'values') || ''

  puts "\n=== #{name} (#{chart} #{version} -> ns/#{namespace}) ==="
  Dir.mktmpdir do |dir|
    values_file = File.join(dir, 'values.yaml')
    File.write(values_file, values)
    ok = run(%(helm upgrade --install #{name} #{chart} --repo #{repo_url} --version #{version} -n #{namespace} --create-namespace -f #{values_file} --wait --timeout 5m))
    failures << name unless ok
  end
end

puts "🔄 Syncing local observability stack + apps directly (bypassing ArgoCD)..."
failures = []

HELM_CHART_APPS.each { |f| sync_helm_app(f, failures) }

puts "\n=== local-apps (frontend/order-service/user-service + observability config) ==="
unless run(%(kubectl apply -k #{File.join(REPO_ROOT, 'apps/local')}))
  failures << 'local-apps'
end

if failures.empty?
  puts "\n✅ Everything synced successfully."
else
  puts "\n⚠️  These failed and may just need a retry (corporate network flakiness): #{failures.join(', ')}"
  puts "   Re-run this script - already-installed releases upgrade quickly, nothing is duplicated."
  exit 1
end
