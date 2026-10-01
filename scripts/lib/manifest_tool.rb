# Small helpers validate.sh uses to pull embedded configs out of rendered
# manifests (Ruby 2.6 compatible).
#
#   manifest_tool.rb configmap FILE KEY [NAME_REGEX]  print data[KEY]
#   manifest_tool.rb secret    FILE KEY [NAME_REGEX]  print decoded data[KEY]
#   manifest_tool.rb rules     FILE OUTDIR            one promtool file per PrometheusRule
#   manifest_tool.rb rules-by-name FILE OUTDIR        same, named <rule>.yaml (for tests)
#   manifest_tool.rb dashboards FILE                  check every grafana_dashboard JSON
require 'base64'
require 'json'
require 'yaml'

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
else
  abort File.read(__FILE__).lines.grep(/^#   /).join
end
