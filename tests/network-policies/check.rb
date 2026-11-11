#!/usr/bin/env ruby
# Checks the NetworkPolicies an environment deploys against the connections
# it must allow and must refuse (flows.yaml next to this file), by
# evaluating the rendered manifests the way Kubernetes does. A policy that
# forgets the mesh's port, a renamed label, or an allow that is wider than
# meant shows up here instead of as a broken (or open) cluster.
#
#   ruby tests/network-policies/check.rb .validate local
#
# Reads what scripts/validate.sh rendered into its output directory: the
# environment's apps, streaming and platform/kong overlays and every Helm
# release (helm/<env>-*.yaml). Pods come from the workloads in them, plus
# the pods operators create (flows.yaml, `pods`). Ruby 2.6 compatible.
#
# Semantics (kubernetes.io/docs/concepts/services-networking/network-policies):
# a pod selected by no policy of a type is open in that direction; once
# selected, only what some rule allows passes, and rules only add. Both the
# sender's egress and the receiver's ingress must allow a connection.
# Traffic from the pod's own node is always allowed in. Pod addresses count
# as inside ipBlocks, as with KinD's plugin and the VPC CNI.
require 'ipaddr'
require 'json'
require 'yaml'

out_dir, env = ARGV
abort "usage: #{$PROGRAM_NAME} <validate-output-dir> <env>" unless out_dir && env

spec = YAML.load_file(File.join(__dir__, 'flows.yaml'))
app_ns = spec.fetch('app_namespaces').fetch(env)
expand = lambda { |s| s.to_s.gsub(/\bAPP\b/, app_ns) }

# --- Load the rendered objects ---------------------------------------------
release_ns = {}
releases = File.join(out_dir, "releases-#{env}.jsonl")
File.foreach(releases) { |l| r = JSON.parse(l); release_ns[r['name']] = r['namespace'] } if File.exist?(releases)
release_ns['traefik'] ||= 'traefik' # the lab's edge, rendered on its own

sources = %W[apps_#{env} streaming_#{env} platform_kong].map { |n| [File.join(out_dir, 'kustomize', "#{n}.yaml"), nil] }
# Argo Workflows and Events (roadmap step 21) and Unleash (step 22) run only
# in some environments.
%W[automation_#{env} feature-flags_#{env}].each do |n|
  file = File.join(out_dir, 'kustomize', "#{n}.yaml")
  sources << [file, nil] if File.exist?(file)
end
Dir[File.join(out_dir, 'helm', "#{env}-*.yaml")].sort.each do |f|
  next if f.end_with?('.inline-values.yaml')
  sources << [f, release_ns[File.basename(f, '.yaml').sub("#{env}-", '')]]
end

objects = []
sources.each do |file, default_ns|
  abort "missing #{file}: run scripts/validate.sh first" unless File.exist?(file)
  YAML.load_stream(File.read(file)) do |doc|
    next unless doc.is_a?(Hash) && doc['kind']
    doc['metadata'] ||= {}
    doc['metadata']['namespace'] ||= default_ns
    objects << doc
  end
end

def strings(hash)
  (hash || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
end

ns_labels = Hash.new { |h, ns| h[ns] = { 'kubernetes.io/metadata.name' => ns } }
objects.select { |o| o['kind'] == 'Namespace' }.each do |o|
  name = o['metadata']['name']
  ns_labels[name] = ns_labels[name].merge(strings(o['metadata']['labels']))
end

Pod = Struct.new(:name, :ns, :labels, :ports, :host_network, :ip)
pods = {}
next_ip = 0
add_pod = lambda do |name, ns, labels, ports, host_network|
  next_ip += 1
  pods["#{ns}/#{name}"] = Pod.new(name, ns, labels, ports, host_network,
                                  IPAddr.new("10.244.#{next_ip / 250}.#{next_ip % 250 + 1}"))
end

objects.each do |o|
  template =
    case o['kind']
    # Rollout: Argo Rollouts (roadmap step 20), a Deployment's pod template.
    when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job', 'Rollout' then o.dig('spec', 'template')
    when 'CronJob' then o.dig('spec', 'jobTemplate', 'spec', 'template')
    end
  next unless template
  labels = strings(template.dig('metadata', 'labels'))
  # Kubernetes labels every Job's pods with the Job's name.
  labels['batch.kubernetes.io/job-name'] = o['metadata']['name'] if o['kind'] == 'Job'
  ports = (template.dig('spec', 'containers') || []).flat_map do |c|
    (c['ports'] || []).map { |p| { 'name' => p['name'], 'port' => p['containerPort'], 'protocol' => p['protocol'] || 'TCP' } }
  end
  add_pod.call(o['metadata']['name'], o['metadata']['namespace'], labels, ports, template.dig('spec', 'hostNetwork') == true)
end

(spec['pods'] || []).each do |p|
  next if p['envs'] && !p['envs'].include?(env)
  ns, name = expand.call(p['name']).split('/', 2)
  ports = (p['ports'] || []).map { |x| { 'name' => x['name'], 'port' => x['port'], 'protocol' => x['protocol'] || 'TCP' } }
  add_pod.call(name, ns, strings(p['labels']), ports, false)
end

Policy = Struct.new(:name, :ns, :selector, :types, :ingress, :egress)
policies = objects.select { |o| o['kind'] == 'NetworkPolicy' }.map do |o|
  s = o['spec'] || {}
  types = s['policyTypes'] || (s['egress'] ? %w[Ingress Egress] : %w[Ingress])
  Policy.new("#{o['metadata']['namespace']}/#{o['metadata']['name']}", o['metadata']['namespace'],
             s['podSelector'] || {}, types, s['ingress'] || [], s['egress'] || [])
end

# --- Evaluation --------------------------------------------------------------
def selects?(selector, labels)
  return true if selector.nil? || selector.empty?
  (selector['matchLabels'] || {}).all? { |k, v| labels[k.to_s] == v.to_s } &&
    (selector['matchExpressions'] || []).all? do |e|
      values = (e['values'] || []).map(&:to_s)
      case e['operator']
      when 'In' then labels.key?(e['key']) && values.include?(labels[e['key']])
      when 'NotIn' then !labels.key?(e['key']) || !values.include?(labels[e['key']])
      when 'Exists' then labels.key?(e['key'])
      when 'DoesNotExist' then !labels.key?(e['key'])
      else abort "unknown selector operator #{e['operator']}"
      end
    end
end

# An endpoint is a pod, the node, or an address outside the cluster.
Endpoint = Struct.new(:pod, :ip, :node) do
  def to_s
    pod ? "#{pod.ns}/#{pod.name}" : (node ? 'node' : "ip:#{ip}")
  end
end
NODE_IP = IPAddr.new('172.18.0.2')

peer_matches = lambda do |peer, policy_ns, ep|
  if peer['ipBlock']
    block = peer['ipBlock']
    next IPAddr.new(block['cidr']).include?(ep.ip) &&
         (block['except'] || []).none? { |x| IPAddr.new(x).include?(ep.ip) }
  end
  next false unless ep.pod && !ep.pod.host_network
  in_ns = peer['namespaceSelector'] ? selects?(peer['namespaceSelector'], ns_labels[ep.pod.ns]) : ep.pod.ns == policy_ns
  in_ns && selects?(peer['podSelector'], ep.pod.labels)
end

# Named ports resolve on the destination pod.
port_matches = lambda do |rule_port, dst, port, proto|
  next false unless (rule_port['protocol'] || 'TCP') == proto
  p = rule_port['port']
  next true if p.nil?
  if p.is_a?(Integer)
    next port == p || (rule_port['endPort'] && port >= p && port <= rule_port['endPort'])
  end
  dst.pod && dst.pod.ports.any? { |cp| cp['name'] == p && cp['port'] == port && cp['protocol'] == proto }
end

rule_allows = lambda do |peers, ports, policy_ns, peer, dst, port, proto|
  (peers.nil? || peers.empty? || peers.any? { |x| peer_matches.call(x, policy_ns, peer) }) &&
    (ports.nil? || ports.empty? || ports.any? { |x| port_matches.call(x, dst, port, proto) })
end

selecting = lambda do |pod, type|
  policies.select { |p| p.ns == pod.ns && p.types.include?(type) && selects?(p.selector, pod.labels) }
end

# Returns nil when allowed, or why not.
verdict = lambda do |src, dst, port, proto|
  if src.pod && !src.pod.host_network
    egress = selecting.call(src.pod, 'Egress')
    unless egress.empty? || egress.any? { |p| p.egress.any? { |r| rule_allows.call(r['to'], r['ports'], p.ns, dst, dst, port, proto) } }
      next "no egress rule of #{egress.map(&:name).join(', ')} allows it"
    end
  end
  if dst.pod && !dst.pod.host_network && !src.node
    ingress = selecting.call(dst.pod, 'Ingress')
    unless ingress.empty? || ingress.any? { |p| p.ingress.any? { |r| rule_allows.call(r['from'], r['ports'], p.ns, src, dst, port, proto) } }
      next "no ingress rule of #{ingress.map(&:name).join(', ')} allows it"
    end
  end
  nil
end

errors = []

endpoint = lambda do |token, flow|
  if token == 'node'
    Endpoint.new(nil, NODE_IP, true)
  elsif token.start_with?('ip:')
    Endpoint.new(nil, IPAddr.new(token.sub('ip:', '')), false)
  elsif (pod = pods[token])
    Endpoint.new(pod, pod.ip, false)
  else
    errors << "#{flow}: no pod #{token} in #{env} (known in that namespace: #{pods.keys.grep(%r{\A#{token.split('/').first}/}).join(', ')})"
    nil
  end
end

meshed = lambda do |pod|
  mode = pod.labels['istio.io/dataplane-mode'] || ns_labels[pod.ns]['istio.io/dataplane-mode']
  mode == 'ambient'
end

checked = 0
%w[allowed refused].each do |want|
  flows = ((spec['all'] || {})[want] || []) + ((spec[env] || {})[want] || [])
  flows.each do |line|
    flow = expand.call(line)
    m = flow.match(%r{\A(\S+)\s*->\s*(\S+):(\d+)(?:/(TCP|UDP|SCTP))?\z}) or (errors << "can't read flow '#{line}'"; next)
    src = endpoint.call(m[1], flow)
    dst = endpoint.call(m[2], flow)
    next unless src && dst
    port = m[3].to_i
    proto = m[4] || 'TCP'
    # A flow must name a port the destination has: its containers' ports,
    # or the mesh's 15008 on a pod in the mesh.
    if dst.pod && !(port == 15_008 && meshed.call(dst.pod)) &&
       dst.pod.ports.none? { |cp| cp['port'] == port && cp['protocol'] == proto }
      errors << "#{flow}: #{dst} has no #{proto} port #{port}#{port == 15_008 ? ' (and is not in the mesh)' : ''}"
      next
    end
    checked += 1
    why = verdict.call(src, dst, port, proto)
    if want == 'allowed' && why
      errors << "should be allowed, is refused: #{flow} (#{why})"
    elsif want == 'refused' && why.nil?
      errors << "should be refused, is allowed: #{flow}"
    end
  end
end

# Every pod in these namespaces must be isolated both ways (default deny).
isolated = (spec['isolated_namespaces'] || []).map { |n| expand.call(n) }
isolated.each do |ns|
  pods.values.select { |p| p.ns == ns && !p.host_network }.each do |pod|
    %w[Ingress Egress].each do |type|
      errors << "#{ns}/#{pod.name} is open for #{type}: no policy selects it" if selecting.call(pod, type).empty?
    end
  end
end

if errors.empty?
  puts "#{env}: #{checked} connections as expected; #{isolated.join(', ')} deny by default (#{policies.size} policies, #{pods.size} pods)"
else
  puts errors
  exit 1
end
