# frozen_string_literal: true

require_relative "hpack_tables"

module ObjectFramework
  module HTTP2
    class ProtocolError < StandardError
      attr_reader :code
      def initialize(message = "HTTP/2 protocol error", code: 1)
        super(message)
        @code = code
      end
    end
    class CompressionError < ProtocolError
      def initialize(message = "Invalid HPACK block"); super(message, code: 9); end
    end
    class StreamError < ProtocolError
      attr_reader :stream_id
      def initialize(stream_id, message = "Invalid HTTP/2 stream", code: 1)
        super(message, code:)
        @stream_id = stream_id
      end
    end

    module HPACK
      module Huffman
        TREE = begin
          root = {}
          HUFFMAN_CODES.each_with_index do |(code, length), symbol|
            node = root
            (length - 1).downto(0) { |bit| node = (node[(code >> bit) & 1] ||= {}) }
            node[:symbol] = symbol
          end
          freeze_tree = ->(node) { node.each_value { |value| freeze_tree.call(value) if value.is_a?(Hash) }; node.freeze }
          freeze_tree.call(root)
        end

        def self.encode(bytes)
          output, bits, length = +"".b, 0, 0
          bytes.each_byte do |byte|
            code, size = HUFFMAN_CODES.fetch(byte)
            bits, length = (bits << size) | code, length + size
            while length >= 8
              length -= 8
              output << ((bits >> length) & 255)
            end
            bits &= (1 << length) - 1
          end
          output << ((bits << (8 - length)) | ((1 << (8 - length)) - 1)) if length.positive?
          output
        end

        def self.decode(bytes, limit: 32 * 1024)
          output, node, tail, tail_size = +"".b, TREE, 0, 0
          bytes.each_byte do |byte|
            7.downto(0) do |index|
              bit = (byte >> index) & 1
              node = node[bit] || raise(CompressionError)
              tail, tail_size = (tail << 1) | bit, tail_size + 1
              if (symbol = node[:symbol])
                raise CompressionError if symbol == 256 || output.bytesize >= limit
                output << symbol
                node, tail, tail_size = TREE, 0, 0
              end
            end
          end
          raise CompressionError if tail_size > 7 || tail != (1 << tail_size) - 1
          output
        end
      end

      module IntegerCoding
        def self.encode(number, prefix:, mask: 0)
          maximum = (1 << prefix) - 1
          return [mask | number].pack("C") if number < maximum
          bytes, number = [mask | maximum].pack("C"), number - maximum
          while number >= 128
            bytes << ((number & 127) | 128)
            number >>= 7
          end
          bytes << number
        end
      end

      class Cursor
        def initialize(bytes); @bytes, @offset = bytes.b, 0; end
        def done?; @offset == @bytes.bytesize; end
        def peek; @bytes.getbyte(@offset) || raise(CompressionError); end

        def take(count)
          raise CompressionError if count.negative? || @offset + count > @bytes.bytesize
          result = @bytes.byteslice(@offset, count)
          @offset += count
          result
        end

        def integer(prefix)
          maximum = (1 << prefix) - 1
          value = take(1).getbyte(0) & maximum
          return value if value < maximum
          9.times do |index|
            byte = take(1).getbyte(0)
            value += (byte & 127) << (index * 7)
            raise CompressionError if value > 2**63 - 1
            return value if byte < 128
          end
          raise CompressionError
        end

        def string(limit:)
          huffman = (peek & 128).positive?
          length = integer(7)
          value = take(length)
          value = Huffman.decode(value, limit:) if huffman
          raise CompressionError if value.bytesize > limit
          value
        end
      end

      class Decoder
        def initialize(table_limit: 4096, header_limit: 32 * 1024)
          @maximum, @capacity, @header_limit = table_limit, table_limit, header_limit
          @dynamic, @size = [], 0
        end

        def decode(bytes)
          cursor, headers, total, saw_header = Cursor.new(bytes), [], 0, false
          until cursor.done?
            first = cursor.peek
            if (first & 128).positive?
              pair = lookup(cursor.integer(7))
            elsif (first & 224) == 32
              raise CompressionError if saw_header
              capacity = cursor.integer(5)
              raise CompressionError if capacity > @maximum
              @capacity = capacity
              evict
              next
            else
              indexed = (first & 64).positive?
              index = cursor.integer(indexed ? 6 : 4)
              name = index.zero? ? cursor.string(limit: @header_limit - total) : lookup(index).first
              value = cursor.string(limit: @header_limit - total)
              pair = [name.freeze, value.freeze].freeze
              add(pair) if indexed
            end
            total += entry_size(pair)
            raise CompressionError if total > @header_limit
            headers << pair
            saw_header = true
          end
          headers.freeze
        end

        private

        def lookup(index)
          raise CompressionError if index.zero?
          (index <= STATIC_TABLE.size ? STATIC_TABLE[index - 1] : @dynamic[index - STATIC_TABLE.size - 1]) || raise(CompressionError)
        end

        def entry_size(pair); pair[0].bytesize + pair[1].bytesize + 32; end

        def add(pair)
          size = entry_size(pair)
          if size > @capacity
            @dynamic.clear
            @size = 0
          else
            @dynamic.unshift(pair)
            @size += size
            evict
          end
        end

        def evict
          @size -= entry_size(@dynamic.pop) while @size > @capacity
        end
      end

      class Encoder
        def encode(headers)
          headers.map do |name, value|
            name, value = name.to_s.b, value.to_s.b
            exact = STATIC_TABLE.index([name, value])
            if exact
              IntegerCoding.encode(exact + 1, prefix: 7, mask: 128)
            else
              index = STATIC_TABLE.index { |pair| pair.first == name }
              # Never index application metadata, including credentials and operation IDs.
              prefix = IntegerCoding.encode(index ? index + 1 : 0, prefix: 4, mask: 16)
              prefix += string(name) unless index
              prefix + string(value)
            end
          end.join.b
        end

        private

        def string(bytes)
          IntegerCoding.encode(bytes.bytesize, prefix: 7) + bytes
        end
      end
    end
  end
end
