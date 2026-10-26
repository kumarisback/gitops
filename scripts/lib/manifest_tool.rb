# Small helpers validate.sh uses to pull embedded configs out of rendered
# manifests (Ruby 2.6 compatible).
#
#   manifest_tool.rb configmap FILE KEY [NAME_REGEX]  print data[KEY]
#   manifest_tool.rb secret    FILE KEY [NAME_REGEX]  print decoded data[KEY]
#   manifest_tool.rb rules     FILE OUTDIR            one promtool file per PrometheusRule
#   manifest_tool.rb rules-by-name FILE OUTDIR        same, named <rule>.yaml (for tests)
#   manifest_tool.rb dashboards FILE                  check every grafana_dashboard JSON
#   manifest_tool.rb env       FILE                   KEY=VALUE for each literal container env var
#   manifest_tool.rb crd-schemas FILE OUTDIR          a kubeconform JSON schema per CRD version,
#                                                     OUTDIR/<group>/<kind>_<version>.json
require 'base64'
require 'fileutils'
require 'json'
require 'yaml'

# A CRD version's openAPIV3Schema as a kubeconform schema, the way
# kubeconform's openapi2jsonschema does it: every object with properties
# rejects unknown fields (strict), except the root (apiVersion, kind,
# metadata) and objects marked x-kubernetes-preserve-unknown-fields;
# int-or-string becomes either type.
def crd_json_schema(node, root = true)
  case node
  when Hash
    if node['x-kubernetes-int-or-string'] || node['format'] == 'int-or-string'
      return { 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }
    end
    out = node.each_with_object({}) do |(k, v), h|
      # Property names are data, not schema keywords.
      h[k] = k == 'properties' && v.is_a?(Hash) ? v.transform_values { |p| crd_json_schema(p, false) } : crd_json_schema(v, false)
    end
    if out.key?('properties') && !root && !out.key?('additionalProperties') && !node['x-kubernetes-preserve-unknown-fields']
      out['additionalProperties'] = false
    end
    out
  when Array
    node.map { |v| crd_json_schema(v, false) }
  else
    node
  end
end

def docs(file)
  YAML.load_stream(File.read(file)).compact.select { |d| d.is_a?(Hash) }
end

def find(file, kind, key, name_re)
  docs(file).find do |d|
    d['kind'] == kind && (name_re.nil? || d.dig('metadata', 'name') =~ Regexp.new(name_re)) &&
      ((d['data'] || {}).key?(key) || (d['stringData'] || {}).key?(key))
  end
end

cmd, file, *rest = ARGV
case cmd
when 'configmap'
  key, re = rest
  doc = find(file, 'ConfigMap', key, re) or abort "no ConfigMap with data.#{key} in #{file}"
  print doc['data'][key]
when 'secret'
  key, re = rest
  doc = find(file, 'Secret', key, re) or abort "no Secret with #{key} in #{file}"
  print(doc.dig('stringData', key) || Base64.decode64(doc['data'][key]))
when 'rules'
  outdir = rest[0]
  count = 0
  docs(file).select { |d| d['kind'] == 'PrometheusRule' }.each do |d|
    name = "#{d.dig('metadata', 'namespace') || 'default'}-#{d.dig('metadata', 'name')}"
    File.write(File.join(outdir, "#{File.basename(file, '.yaml')}--#{name}.yaml"),
               { 'groups' => d.dig('spec', 'groups') || [] }.to_yaml)
    count += 1
  end
  puts count
when 'rules-by-name'
  outdir = rest[0]
  docs(file).select { |d| d['kind'] == 'PrometheusRule' }.each do |d|
    File.write(File.join(outdir, "#{d.dig('metadata', 'name')}.yaml"),
               { 'groups' => d.dig('spec', 'groups') || [] }.to_yaml)
  end
when 'env'
  docs(file).select { |d| %w[Deployment StatefulSet DaemonSet].include?(d['kind']) }.each do |d|
    (d.dig('spec', 'template', 'spec', 'containers') || []).each do |c|
      (c['env'] || []).each { |e| puts "#{e['name']}=#{e['value']}" if e.key?('value') }
    end
  end
when 'dashboards'
  count = 0
  docs(file).select { |d| d['kind'] == 'ConfigMap' && d.dig('metadata', 'labels', 'grafana_dashboard') }.each do |d|
    (d['data'] || {}).each do |k, v|
      begin
        JSON.parse(v)
      rescue JSON::ParserError => e
        abort "#{d.dig('metadata', 'name')}/#{k}: #{e.message[0, 200]}"
      end
      count += 1
    end
  end
  puts count
when 'crd-schemas'
  outdir = rest[0]
  count = 0
  docs(file).select { |d| d['kind'] == 'CustomResourceDefinition' }.each do |d|
    group = d.dig('spec', 'group')
    kind = d.dig('spec', 'names', 'kind').downcase
    (d.dig('spec', 'versions') || []).each do |v|
      schema = v.dig('schema', 'openAPIV3Schema') or next
      FileUtils.mkdir_p(File.join(outdir, group))
      File.write(File.join(outdir, group, "#{kind}_#{v['name']}.json"), JSON.generate(crd_json_schema(schema)))
      count += 1
    end
  end
  puts count
else
  abort File.read(__FILE__).lines.grep(/^#   /).join
end
