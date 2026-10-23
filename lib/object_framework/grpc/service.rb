# frozen_string_literal: true

module ObjectFramework
  # Native gRPC services and streaming over the framework's HTTP/2 transport.
  module GRPC
    Method = Data.define(:name, :input, :output, :controller, :client_streaming, :server_streaming)

    # Declares a gRPC service using Protobuf::Message contracts.
    # Descriptors export proto3 source without generated Ruby message classes.
    class Service
      attr_reader :name, :methods

      # +name+ is a qualified service name, for example +orders.Orders+.
      def initialize(name)
        parts = name.to_s.split(".", -1)
        raise ConfigurationError, "Invalid service name" if parts.empty?
        parts.each { |part| Protobuf.name(part) }
        @name, @methods = name.to_s.dup.freeze, {}
      end

      # Adds an RPC with input/output message descriptors and a controller key.
      # Both streaming flags default to false (unary); enable one for client
      # or server streaming, or both for bidirectional streaming. Returns +self+.
      def rpc(name, input:, output:, controller:, client_streaming: false, server_streaming: false)
        raise ConfigurationError, "Service is finalized" if @methods.frozen?
        name = Protobuf.name(name)
        raise ConfigurationError, "Duplicate RPC method" if @methods.key?(name)
        raise ConfigurationError, "RPC contracts require message descriptors" unless input.is_a?(Protobuf::Message) && output.is_a?(Protobuf::Message)
        @methods[name] = Method.new(name:, input:, output:, controller:, client_streaming:, server_streaming:)
        self
      end

      def finalize!
        to_proto
        @methods.freeze
        freeze
      end

      # Returns a complete proto3 contract with dependent messages and enums.
      # Raises ConfigurationError if distinct descriptors reuse a type name.
      def to_proto
        definitions = {}
        visit = lambda do |type|
          if definitions.key?(type.name)
            raise ConfigurationError, "Ambiguous protobuf type name: #{type.name}" unless definitions[type.name].equal?(type)
            return
          end
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
