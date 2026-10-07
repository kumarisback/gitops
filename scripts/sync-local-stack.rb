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
# (bootstrap/envs/local, rendered with kustomize, plus the addons/values
# files they reference) so chart/version/values/namespace stay in sync with
# what's committed - it's a direct-apply mirror of that intent,
# not a separate source of truth. ArgoCD is left running for its UI/history;
# this just doesn't depend on it actually reconciling.
#
# Usage: ./scripts/sync-local-stack.rb [--dry-run]
#   --dry-run  print the helm/kubectl commands without running them
require 'tmpdir'
require 'json'
require_relative 'lib/addon_releases'

REPO_ROOT = File.expand_path('..', __dir__)
DRY_RUN = ARGV.include?('--dry-run')

def run(cmd)
  puts "+ #{cmd}"
  DRY_RUN || system(cmd)
end

def sync_helm_app(release, failures)
  puts "\n=== #{release['name']} (#{release['chart']} #{release['version']} -> ns/#{release['namespace']}) ==="
  Dir.mktmpdir do |dir|
    files = release['value_files'].dup
    if release['inline_values']
      inline = File.join(dir, 'inline-values.yaml')
      File.write(inline, release['inline_values'])
      files.unshift(inline)
    end
    value_args = files.map { |f| "-f #{f}" }.join(' ')
    # A chart from this repo (charts/microservice) is installed from its
    # directory, after building its file:// dependencies from Chart.lock.
    # --take-ownership (Helm 3.17+) adopts objects kubectl applied before:
    # a lab created when the service was still deployed with Kustomize.
    source = if release['local']
               run(%(helm dependency build #{release['chart']})) or (failures << release['name'] and return)
               "#{release['chart']} --take-ownership"
             else
               "#{release['chart']} --repo #{release['repo']} --version #{release['version']}"
             end
    ok = run(%(helm upgrade --install #{release['name']} #{source} -n #{release['namespace']} --create-namespace #{value_args} --wait --timeout 5m))
    failures << release['name'] unless ok
  end
end

# This script and ArgoCD must not both own the stack: an auto-syncing
# Application resets everything to what's pushed on GitHub (undoing
# working-tree changes applied here) and prunes what isn't there. Turn
# auto-sync off on any Application that still has it; the resources stay
# put. Root first, or it re-enables auto-sync on its children.
# Re-applying bootstrap/root-app-local.yaml turns it back on.
def disable_argocd_autosync
  return if DRY_RUN

  out = `kubectl get applications.argoproj.io -n argocd -o json 2>/dev/null`
  return unless $?.success?

  names = JSON.parse(out)['items']
              .select { |app| app.dig('spec', 'syncPolicy', 'automated') }
              .map { |app| app.dig('metadata', 'name') }
  return if names.empty?

  names = names.partition { |n| n == 'root-app-local' }.flatten
  puts "⏸️  Turning off ArgoCD auto-sync so it doesn't undo this sync: #{names.join(', ')}"
  names.each do |name|
    run(%(kubectl patch applications.argoproj.io #{name} -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'))
  end
end

puts "🔄 Syncing local observability stack + apps directly (bypassing ArgoCD)..."
failures = []

disable_argocd_autosync

AddonReleases.for('bootstrap/envs/local').each { |r| sync_helm_app(r, failures) }

# Directory-based Applications: the services (apps/local) and the alerting
# rules + dashboards (observability/local).
AddonReleases.paths('bootstrap/envs/local').each do |app|
  puts "\n=== #{app['name']} (#{app['path']}) ==="
  failures << app['name'] unless run(%(kubectl apply -k #{File.join(REPO_ROOT, app['path'])}))
end

if failures.empty?
  puts "\n✅ Everything synced successfully."
else
  puts "\n⚠️  These failed and may just need a retry (corporate network flakiness): #{failures.join(', ')}"
  puts "   Re-run this script - already-installed releases upgrade quickly, nothing is duplicated."
  exit 1
end
