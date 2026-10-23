# frozen_string_literal: true

require "object_framework"
require "json"

class Calculation
  def initialize(increment:)
    @increment = increment
  end

  def call(input:)
    { value: input * input + @increment }
  end
end

abort "Ruby 4.0.8 is required" unless RUBY_VERSION == "4.0.8"
iterations = Integer(ARGV.fetch(0, "20000"))
abort "Iterations must be positive" unless iterations.positive?
app = ObjectFramework::Application.new
app.factory(:increment) { 1 }
app.operation(:calculate, use_case: Calculation, policy: :none, dependencies: [:increment])
app.start
begin
  2_000.times { |index| app.invoke(:calculate, input: index) }
  GC.start
  before = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  checksum = 0
  iterations.times { |index| checksum += app.invoke(:calculate, input: index)[:value] }
  duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts JSON.generate(ruby: RUBY_VERSION, mode: RubyVM::YJIT.enabled? ? "yjit" : RubyVM::ZJIT.enabled? ? "zjit" : "interpreter",
    iterations:, seconds: duration, allocated_objects: GC.stat(:total_allocated_objects) - before, checksum:)
ensure
  app.stop
end
