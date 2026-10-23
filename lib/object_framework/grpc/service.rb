# frozen_string_literal: true

module ObjectFramework
  module GRPC
    Method = Data.define(:name, :input, :output, :controller, :client_streaming, :server_streaming)

    class Service
      attr_reader :name, :methods

      def initialize(name)
        name.to_s.split(".").each { |part| Protobuf.name(part) }
        @name, @methods = name.to_s.dup.freeze, {}
      end

      def rpc(name, input:, output:, controller:, client_streaming: false, server_streaming: false)
        raise ConfigurationError, "Service is finalized" if @methods.frozen?
        name = Protobuf.name(name)
        raise ConfigurationError, "Duplicate RPC method" if @methods.key?(name)
        raise ConfigurationError, "RPC contracts require message descriptors" unless input.is_a?(Protobuf::Message) && output.is_a?(Protobuf::Message)
        @methods[name] = Method.new(name:, input:, output:, controller:, client_streaming:, server_streaming:)
        self
      end

      def finalize!; @methods.freeze; self; end

      def to_proto
        definitions = {}
        visit = lambda do |type|
          return if definitions.key?(type.name)
          definitions[type.name] = type
          type.dependencies.each { |child| visit.call(child) } if type.is_a?(Protobuf::Message)
        end
        @methods.each_value { |method| visit.call(method.input); visit.call(method.output) }
        package = name.split(".")[0...-1].join(".")
        output = "syntax = \"proto3\";\n"
        output += "package #{package};\n" unless package.empty?
        output += "\n" + definitions.values.map(&:definition).join("\n")
        output += "\nservice #{name.split('.').last} {\n"
        @methods.each_value do |method|
          output += "  rpc #{method.name} (#{method.client_streaming ? 'stream ' : ''}#{method.input.name}) returns (#{method.server_streaming ? 'stream ' : ''}#{method.output.name});\n"
        end
        output + "}\n"
      end
    end
  end
end
