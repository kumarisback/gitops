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
LOGICAL_KEYWORDS = %w[oneOf anyOf allOf not].freeze

# In a CRD, oneOf/anyOf/allOf/not only constrain fields declared next to
# them (Kubernetes structural schemas); their own "properties" list some of
# those fields. So nothing inside them may forbid other properties.
def crd_json_schema(node, root = true, in_logical = false)
  case node
  when Hash
    if node['x-kubernetes-int-or-string'] || node['format'] == 'int-or-string'
      return { 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }
    end
    out = node.each_with_object({}) do |(k, v), h|
      logical = in_logical || LOGICAL_KEYWORDS.include?(k)
      # Property names are data, not schema keywords.
      h[k] = if k == 'properties' && v.is_a?(Hash)
               v.transform_values { |p| crd_json_schema(p, false, logical) }
             else
               crd_json_schema(v, false, logical)
             end
    end
    if out.key?('properties') && !root && !in_logical && !out.key?('additionalProperties') &&
       !node['x-kubernetes-preserve-unknown-fields']
      out['additionalProperties'] = false
    end
    out
  when Array
    node.map { |v| crd_json_schema(v, false, in_logical) }
  else
    node
  end
end

def docs(file)
  YAML.load_stream(File.read(file)).compact.select { |d| d.is_a?(Hash) }
end

# Built-in kinds without a namespace, as group/kind (core group: "").
CLUSTER_SCOPED_KINDS = %w[
  /Namespace /Node /PersistentVolume
  rbac.authorization.k8s.io/ClusterRole rbac.authorization.k8s.io/ClusterRoleBinding
  apiextensions.k8s.io/CustomResourceDefinition apiregistration.k8s.io/APIService
  admissionregistration.k8s.io/ValidatingWebhookConfiguration
  admissionregistration.k8s.io/MutatingWebhookConfiguration
  admissionregistration.k8s.io/ValidatingAdmissionPolicy
  admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding
  storage.k8s.io/StorageClass storage.k8s.io/CSIDriver storage.k8s.io/VolumeAttachment
  scheduling.k8s.io/PriorityClass networking.k8s.io/IngressClass node.k8s.io/RuntimeClass
  flowcontrol.apiserver.k8s.io/FlowSchema flowcontrol.apiserver.k8s.io/PriorityLevelConfiguration
  certificates.k8s.io/CertificateSigningRequest
].freeze

def group_kind(doc)
  api = doc['apiVersion'].to_s
  "#{api.include?('/') ? api.split('/').first : ''}/#{doc['kind']}"
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
# A namespace on a cluster-scoped object is a mistake (usually a Kustomize
# namespace transformer stamping a kind it doesn't know), and schemas don't
# catch it. Cluster-scoped kinds: the built-ins plus every rendered CRD
# with scope Cluster.
when 'scope-check'
  all = [file, *rest].flat_map { |f| docs(f).map { |d| [f, d] } }
  cluster = CLUSTER_SCOPED_KINDS.dup
  all.each do |_, d|
    next unless d['kind'] == 'CustomResourceDefinition' && d.dig('spec', 'scope') == 'Cluster'

    cluster << "#{d.dig('spec', 'group')}/#{d.dig('spec', 'names', 'kind')}"
  end
  bad = all.select { |_, d| d.dig('metadata', 'namespace') && cluster.include?(group_kind(d)) }
  bad.each do |f, d|
    warn "#{File.basename(f)}: #{d['kind']} #{d.dig('metadata', 'name')} is cluster-scoped but has namespace #{d.dig('metadata', 'namespace')}"
  end
  abort "#{bad.size} cluster-scoped objects with a namespace" unless bad.empty?
  puts "#{all.size} objects, #{cluster.uniq.size} cluster-scoped kinds"
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
