# frozen_string_literal: true

require "open3"
require "rbconfig"
require "json"
require "time"

iterations = Integer(ARGV.fetch(0, "20000"))
samples = Integer(ARGV.fetch(1, "3"))
abort "Iterations and samples must be positive" unless iterations.positive? && samples.positive?
root = File.expand_path("..", __dir__)
modes = { "interpreter" => %w[--disable-yjit --disable-zjit],
          "yjit" => %w[--disable-zjit --yjit], "zjit" => %w[--disable-yjit --zjit] }
results = modes.map do |mode, flags|
  measurements = samples.times.map do
    output, error, status = Open3.capture3(RbConfig.ruby, *flags, "-I#{root}/lib", File.join(__dir__, "workload.rb"), iterations.to_s)
    abort "#{mode} failed: #{error}" unless status.success?
    record = JSON.parse(output)
    abort "#{mode} was not enabled by this Ruby build" unless record.fetch("mode") == mode
    record
  end
  times = measurements.map { |record| record.fetch("seconds") }.sort
  { mode:, median_seconds: times[times.size / 2], samples: measurements }
end
checksums = results.flat_map { |result| result[:samples].map { |sample| sample.fetch("checksum") } }
abort "Modes produced different results" unless checksums.uniq.size == 1
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, measured_at: Time.now.utc.iso8601,
  workload: "Scoped, detached application invocations; 2000 warmup calls per process", results:)
