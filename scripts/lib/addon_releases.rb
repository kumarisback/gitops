# Lists the Helm releases an environment's ArgoCD Applications install, with
# each one's value files resolved to paths in this repo, by rendering
# bootstrap/envs/<env> exactly as ArgoCD does. Shared by sync-local-stack.rb
# and validate.sh so neither keeps its own copy of chart versions or values.
#
#   ruby scripts/lib/addon_releases.rb bootstrap/envs/dev   # one JSON per line
#
# Ruby 2.6 compatible (macOS system Ruby).
require 'json'
require 'yaml'

module AddonReleases
  REPO_ROOT = File.expand_path('../..', __dir__)

  # kube-prometheus-stack installs the Prometheus Operator CRDs that the
  # other charts' ServiceMonitors need, so it goes first.
  FIRST = %w[kube-prometheus-stack].freeze

  def self.render(env_dir)
    out = IO.popen(['kubectl', 'kustomize', '--load-restrictor', 'LoadRestrictionsNone',
                    File.join(REPO_ROOT, env_dir)], &:read)
    raise "kubectl kustomize #{env_dir} failed" unless $?.success?
    YAML.load_stream(out).compact
  end

  def self.for(env_dir)
    releases = render(env_dir).select { |d| d['kind'] == 'Application' }.map do |app|
      spec = app['spec']
      sources = spec['sources'] || [spec['source']]
      chart = sources.find { |s| s['chart'] }
      next unless chart

      helm = chart['helm'] || {}
      value_files = (helm['valueFiles'] || []).map { |f| f.sub(%r{\A\$values/}, "#{REPO_ROOT}/") }
      missing = value_files.reject { |f| File.exist?(f) }
      unless missing.empty? || helm['ignoreMissingValueFiles']
        raise "#{app['metadata']['name']}: missing value files #{missing.join(', ')}"
      end

      {
        'name' => helm['releaseName'] || app['metadata']['name'],
        'chart' => chart['chart'],
        'repo' => chart['repoURL'],
        'version' => chart['targetRevision'],
        'namespace' => spec.dig('destination', 'namespace'),
        'value_files' => value_files.select { |f| File.exist?(f) }.uniq,
        'inline_values' => helm['values']
      }
    end.compact
    releases.sort_by { |r| [FIRST.index(r['name']) || FIRST.size, r['name']] }
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: #{$PROGRAM_NAME} bootstrap/envs/<env>" unless ARGV.size == 1
  AddonReleases.for(ARGV[0]).each { |r| puts JSON.generate(r) }
end
