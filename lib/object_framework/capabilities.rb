# frozen_string_literal: true

module ObjectFramework
  module Capabilities
    class Unsupported < ConfigurationError; end

    class TaskFailure < StandardError
      attr_reader :remote_class
      def initialize(remote_class:, message:, backtrace:)
        @remote_class = remote_class
        super(message)
        set_backtrace(backtrace)
      end
    end

    def self.report
      { ruby_box: Ruby::Box.enabled?, ractor: defined?(::Ractor) != nil,
        yjit: RubyVM::YJIT.enabled?, zjit: RubyVM::ZJIT.enabled? }.freeze
    end

    class Definitions
      def initialize
        raise Unsupported, "Enable Ruby Box at process boot with RUBY_BOX=1" unless Ruby::Box.enabled?
        @box = Ruby::Box.new
      end

      def load(path); @box.load(File.expand_path(path)); end
      def require(path); @box.require(path); end
      def evaluate(source); @box.eval(source); end
      def constant(name); @box.const_get(name, false); end
    end

    class IsolatedTask
      def initialize(task:)
        raise ConfigurationError, "An isolated task must be a class or module implementing call" unless task.is_a?(Module) && task.respond_to?(:call)
        @task = task
      end

      def call(input, context: nil)
        context&.cancellation&.check!
        payload = Values.detach(input)
        # Only independent values cross this boundary; the request keeps its session.
        ractor = Ractor.new(@task, payload) do |task, values|
          begin
            [:success, ObjectFramework::Values.detach(task.call(values))]
          rescue StandardError => error
            [:failure, error.class.name, error.message, error.backtrace]
          end
        end
        outcome, *result = ractor.value
        context&.cancellation&.check!
        if outcome == :failure
          raise TaskFailure.new(remote_class: result[0], message: result[1], backtrace: result[2])
        end
        Values.detach(result.first)
      end
    end
  end
end
