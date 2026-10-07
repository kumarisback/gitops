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
  # other charts' ServiceMonitors need, so it goes first. Charts from this
  # repo (the services) come after every add-on, whose CRDs they use (VPA,
  # ServiceMonitor).
  FIRST = %w[kube-prometheus-stack].freeze

  # A source pointing at a directory of this repo that holds a Chart.yaml
  # (charts/microservice): ArgoCD renders it as a Helm chart.
  def self.local_chart?(source)
    source && source['path'] && !source['chart'] &&
      File.exist?(File.join(REPO_ROOT, source['path'], 'Chart.yaml'))
  end

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
      chart = sources.find { |s| s['chart'] } || sources.find { |s| local_chart?(s) }
      next unless chart

      local = local_chart?(chart)
      helm = chart['helm'] || {}
      # Remote charts take value files from the $values source (this repo);
      # a local chart's are relative to its own directory.
      value_files = (helm['valueFiles'] || []).map do |f|
        local ? File.expand_path(f, File.join(REPO_ROOT, chart['path'])) : f.sub(%r{\A\$values/}, "#{REPO_ROOT}/")
      end
      missing = value_files.reject { |f| File.exist?(f) }
      unless missing.empty? || helm['ignoreMissingValueFiles']
        raise "#{app['metadata']['name']}: missing value files #{missing.join(', ')}"
      end

      {
        'name' => helm['releaseName'] || app['metadata']['name'],
        'chart' => local ? File.join(REPO_ROOT, chart['path']) : chart['chart'],
        'local' => local,
        'repo' => local ? nil : chart['repoURL'],
        'version' => local ? nil : chart['targetRevision'],
        'namespace' => spec.dig('destination', 'namespace'),
        'value_files' => value_files.select { |f| File.exist?(f) }.uniq,
        'inline_values' => helm['values']
      }
    end.compact
    releases.sort_by { |r| [r['local'] ? 1 : 0, FIRST.index(r['name']) || FIRST.size, r['name']] }
  end
end

module AddonReleases
  # Applications that point at a directory of this repo (kustomize), e.g.
  # local-apps -> apps/local, observability-config -> observability/local.
  def self.paths(env_dir)
    render(env_dir).select { |d| d['kind'] == 'Application' }.map do |app|
      source = app.dig('spec', 'source')
      next unless source && source['path'] && !source['chart'] && !local_chart?(source)

      { 'name' => app['metadata']['name'], 'path' => source['path'],
        'namespace' => app.dig('spec', 'destination', 'namespace') }
    end.compact.sort_by { |a| a['name'] }
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: #{$PROGRAM_NAME} bootstrap/envs/<env>" unless ARGV.size == 1
  AddonReleases.for(ARGV[0]).each { |r| puts JSON.generate(r) }
end
