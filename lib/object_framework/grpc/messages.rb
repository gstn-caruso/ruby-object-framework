# frozen_string_literal: true

module ObjectFramework
  module GRPC
    class Unimplemented < StandardError; end

    class Messages
      include Enumerable

      def self.frame(bytes)
        [0, bytes.bytesize].pack("CN") + bytes.b
      end

      def initialize(input:, descriptor:, message_limit: 1024 * 1024)
        @input, @descriptor, @limit = input, descriptor, message_limit
      end

      def each
        return enum_for(:each) unless block_given?
        while (header = @input.read_exact(5, allow_eof: true))
          compressed, length = header.unpack("CN")
          raise InvalidInput, "Invalid gRPC compression flag" unless [0, 1].include?(compressed)
          raise Unimplemented, "Message compression is not supported" if compressed == 1
          raise CapacityExceeded, "Message exceeds configured limit" if length > @limit
          yield @descriptor.decode(@input.read_exact(length))
        end
      end
    end
  end
end
