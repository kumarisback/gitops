#!/usr/bin/env ruby
# Runs the loki.process "pod_logs" block from addons/values/common/alloy.yaml
# in a real Alloy, feeding it the cases in pipeline_cases.yaml from files
# and capturing what reaches loki.echo, then compares. Needs `alloy` on PATH.
# Ruby 2.6 compatible.
require 'socket'
require 'tmpdir'
require 'yaml'

ROOT = File.expand_path('../..', __dir__)
cases = YAML.load_file(File.join(__dir__, 'pipeline_cases.yaml'))['cases']
content = YAML.load_file(File.join(ROOT, 'addons/values/common/alloy.yaml'))['alloy']['configMap']['content']

# Pull out the loki.process "pod_logs" { ... } block by brace matching,
# skipping braces inside strings and // comments.
start = content.index('loki.process "pod_logs"') or abort 'loki.process "pod_logs" not found'
depth = 0; i = content.index('{', start); in_str = false; esc = false
while i < content.size
  c = content[i]
  if in_str
    esc = !esc && c == '\\'
    in_str = false if c == '"' && !esc && content[i - 1] != '\\' || (c == '"' && !esc && content[i - 1] == '\\' && content[i - 2] == '\\')
  elsif c == '/' && content[i + 1] == '/'
    i = content.index("\n", i)
    next
  elsif c == '"'
    in_str = true
  elsif c == '{'
    depth += 1
  elsif c == '}'
    depth -= 1
    break if depth.zero?
  end
  i += 1
end
block = content[start..i].sub('forward_to = [loki.write.default.receiver]', 'forward_to = [loki.echo.out.receiver]')

failures = []
Dir.mktmpdir do |dir|
  targets = cases.each_with_index.map do |c, n|
    path = File.join(dir, "case#{n}.log")
    File.write(path, c['lines'].join("\n") + "\n")
    %({"__path__" = "#{path}", "container" = "#{c['container']}", "namespace" = "#{c['namespace'] || 'development'}", "case" = "#{n}"})
  end
  File.write(File.join(dir, 'test.alloy'), <<~ALLOY)
    local.file_match "cases" {
      path_targets = [#{targets.join(', ')}]
    }
    loki.source.file "cases" {
      targets    = local.file_match.cases.targets
      forward_to = [loki.process.pod_logs.receiver]
    }
    #{block}
    loki.echo "out" { }
  ALLOY

  log = File.join(dir, 'alloy.log')
  port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] } # Alloy needs a real port
  pid = spawn('alloy', 'run', "--server.http.listen-addr=127.0.0.1:#{port}", "--storage.path=#{dir}/data",
              File.join(dir, 'test.alloy'), out: log, err: log)
  sleep 8 # multiline blocks flush after max_wait_time (3s)
  Process.kill('TERM', pid)
  Process.wait(pid)

  got = Hash.new { |h, k| h[k] = [] }
  File.foreach(log) do |l|
    next unless l.include?('msg="received log entry"')
    entry = l[/ entry=("(?:[^"\\]|\\.)*")/, 1].undump
    labels = Hash[l[/ labels=("(?:[^"\\]|\\.)*")/, 1].undump.scan(/(\w+)="((?:[^"\\]|\\.)*)"/)]
    got[labels['case'].to_i] << { 'line' => entry, 'log_type' => labels['log_type'],
                                  'tenant' => labels['__tenant_id__'] }
  end
  if got.empty?
    puts File.read(log).lines.last(20).join
    abort 'no entries reached loki.echo (see Alloy log above)'
  end

  cases.each_with_index do |c, n|
    # Compare only the keys each expected entry names.
    same = got[n].size == c['expect'].size &&
           got[n].zip(c['expect']).all? { |g, e| e.all? { |k, v| g[k] == v } }
    if same
      puts "  ok   #{c['name']}"
    else
      failures << c['name']
      puts "  FAIL #{c['name']}"
      puts "       expected: #{c['expect'].inspect}"
      puts "       got:      #{got[n].inspect}"
    end
  end
end
abort "#{failures.size} of #{cases.size} log pipeline cases failed" unless failures.empty?
puts "#{cases.size} log pipeline cases passed"
