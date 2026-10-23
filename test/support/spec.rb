# frozen_string_literal: true

module Spec
  class Failure < StandardError; end
  @examples = []

  def self.test(name, &block)
    @examples << [name, block]
  end

  def self.run
    failures = 0
    @examples.each do |name, block|
      Object.new.extend(Assertions).instance_exec(&block)
      puts "PASS #{name}"
    rescue StandardError => error
      failures += 1
      warn "FAIL #{name}: #{error.class}: #{error.message}\n  #{error.backtrace.first(6).join("\n  ")}"
    end
    puts "#{@examples.size} tests, #{failures} failures"
    failures.zero? ? 0 : 1
  end

  module Assertions
    def assert(value, message = "Expected a truthy value")
      raise Failure, message unless value
    end

    def assert_equal(expected, actual)
      assert expected == actual, "Expected #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_same(expected, actual)
      assert expected.equal?(actual), "Expected the same object"
    end

    def assert_raises(type)
      begin
        yield
      rescue type => error
        return error
      end
      raise Failure, "Expected #{type}"
    end
  end
end
