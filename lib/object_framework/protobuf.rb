# frozen_string_literal: true

module ObjectFramework
  # Ruby descriptors and wire encoding for proto3 messages and enums.
  module Protobuf
    SCALARS = {
      int32: 0, int64: 0, uint32: 0, uint64: 0, sint32: 0, sint64: 0, bool: 0,
      fixed64: 1, sfixed64: 1, double: 1, string: 2, bytes: 2,
      fixed32: 5, sfixed32: 5, float: 5
    }.freeze

    def self.name(value)
      raise ConfigurationError, "Invalid protobuf name" unless /\A[A-Za-z_][A-Za-z_0-9]*\z/.match?(value.to_s)
      value.to_s.dup.freeze
    end

    module Wire
      def self.varint(value)
        raise InvalidInput, "Varint is out of range" unless value.is_a?(Integer) && value.between?(0, 2**64 - 1)
        bytes = +"".b
        while value >= 128
          bytes << ((value & 127) | 128)
          value >>= 7
        end
        bytes << value
      end

      class Cursor
        attr_reader :position
        def initialize(bytes); @bytes, @position = bytes.b, 0; end
        def done?; @position == @bytes.bytesize; end

        def take(count)
          raise InvalidInput, "Truncated protobuf field" if count.negative? || @position + count > @bytes.bytesize
          result = @bytes.byteslice(@position, count)
          @position += count
          result
        end

        def varint
          result = 0
          10.times do |index|
            byte = take(1).getbyte(0)
            raise InvalidInput, "Varint overflow" if index == 9 && byte > 1
            result |= (byte & 127) << (index * 7)
            return result if byte < 128
          end
          raise InvalidInput, "Varint overflow"
        end

        def skip(wire)
          case wire
          when 0 then varint
          when 1 then take(8)
          when 2 then take(varint)
          when 5 then take(4)
          else raise InvalidInput, "Unsupported protobuf wire type"
          end
        end
      end
    end

    # Immutable proto3 enum declaration. Its first value must be zero, and
    # names and numeric values must be unique and valid for proto3.
    class Enum
      attr_reader :name, :values
      def initialize(name, **values)
        @name, @values = Protobuf.name(name), values.dup.freeze
        raise ConfigurationError, "A proto3 enum must begin with zero" unless values.values.first == 0
        raise ConfigurationError, "Duplicate enum value" unless values.values.uniq.size == values.size
        values.each { |key, value| Protobuf.name(key); raise ConfigurationError, "Invalid enum value" unless value.is_a?(Integer) && value.between?(-(2**31), 2**31 - 1) }
        freeze
      end

      def definition
        "enum #{name} {\n" + values.map { |key, value| "  #{key} = #{value};\n" }.join + "}\n"
      end
    end

    Field = Data.define(:name, :number, :type, :repeated, :packed)

    # Immutable message descriptor encoding and decoding ordinary value hashes.
    # Declare fields in the construction block.
    #
    #   message = ObjectFramework::Protobuf::Message.new("Greeting") do
    #     field :text, 1, :string
    #   end
    #   bytes = message.encode(text: "Hello")
    #   message.decode(bytes) # => { text: "Hello" }
    class Message
      attr_reader :name, :fields

      def initialize(name, &declaration)
        @name, @fields = Protobuf.name(name), []
        instance_eval(&declaration) if declaration
        @numbers = fields.to_h { |field| [field.number, field] }.freeze
        @fields.freeze
        freeze
      end

      # Declares a unique field name and proto3 number. +type+ is a scalar in
      # SCALARS, another Message, or an Enum. Repeated numeric fields use packed
      # encoding by default. Declare fields only during construction.
      def field(name, number, type, repeated: false, packed: true)
        name = Protobuf.name(name).to_sym
        unless number.is_a?(Integer) && number.between?(1, 2**29 - 1) && !number.between?(19_000, 19_999)
          raise ConfigurationError, "Invalid protobuf field number"
        end
        raise ConfigurationError, "Duplicate protobuf field" if fields.any? { |field| field.name == name || field.number == number }
        raise ConfigurationError, "Unknown protobuf type" unless SCALARS.key?(type) || type.is_a?(Message) || type.is_a?(Enum)
        @fields << Field.new(name:, number:, type:, repeated:, packed:)
      end

      # Encodes a Hash or Data value, or keyword attributes, as binary proto3.
      # Raises InvalidInput for unknown fields, invalid values, or excessive
      # nesting. Repeated fields require arrays.
      def encode(values = nil, depth: 0, **attributes)
        raise InvalidInput, "Protobuf nesting limit exceeded" if depth >= 64
        raise InvalidInput, "Pass message values once" if values && !attributes.empty?
        values ||= attributes
        values = values.to_h if values.is_a?(Data)
        raise InvalidInput, "Expected protobuf message values" unless values.is_a?(Hash)
        values = values.transform_keys { |key| key.to_s.to_sym }
        raise InvalidInput, "Unknown protobuf field" unless (values.keys - fields.map(&:name)).empty?
        fields.each_with_object(+"".b) do |field, output|
          next unless values.key?(field.name)
          value = values[field.name]
          if field.repeated
            raise InvalidInput, "Repeated fields require arrays" unless value.is_a?(Array)
            if packable?(field) && field.packed && !value.empty?
              payload = value.map { |item| encode_value(field.type, item, depth:) }.join.b
              output << Wire.varint((field.number << 3) | 2) << Wire.varint(payload.bytesize) << payload
            else
              value.each { |item| output << encode_field(field, item, depth:) }
            end
          elsif !default?(field.type, value)
            output << encode_field(field, value, depth:)
          end
        end
      end

      # Decodes binary proto3 into a Hash, supplying defaults for absent fields
      # and skipping unknown fields. Malformed input raises InvalidInput.
      def decode(bytes, depth: 0, initial: nil)
        raise InvalidInput, "Protobuf nesting limit exceeded" if depth >= 64
        cursor = Wire::Cursor.new(bytes)
        result = initial ? Values.mutable_copy(initial) : fields.to_h { |field| [field.name, default_value(field)] }
        until cursor.done?
          tag = cursor.varint
          number, wire = tag >> 3, tag & 7
          raise InvalidInput, "Invalid protobuf field tag" unless number.between?(1, 2**29 - 1)
          field = @numbers[number]
          if field && field.repeated && packable?(field) && wire == 2
            packed = Wire::Cursor.new(cursor.take(cursor.varint))
            result[field.name] << decode_value(field.type, packed, depth:) until packed.done?
          elsif field && wire == wire_type(field.type)
            value = decode_value(field.type, cursor, depth:, initial: field.type.is_a?(Message) && !field.repeated ? result[field.name] : nil)
            field.repeated ? result[field.name] << value : result[field.name] = value
          else
            cursor.skip(wire)
          end
        end
        Values.detach(result)
      end

      def dependencies
        fields.map(&:type).select { |type| type.is_a?(Message) || type.is_a?(Enum) }
      end

      def definition
        "message #{name} {\n" + fields.map do |field|
          type = field.type.respond_to?(:name) ? field.type.name : field.type.to_s
          option = field.repeated && packable?(field) && !field.packed ? " [packed = false]" : ""
          "  #{field.repeated ? 'repeated ' : ''}#{type} #{field.name} = #{field.number}#{option};\n"
        end.join + "}\n"
      end

      private

      def wire_type(type)
        return 2 if type.is_a?(Message)
        return 0 if type.is_a?(Enum)
        SCALARS.fetch(type)
      end

      def packable?(field); wire_type(field.type) != 2; end

      def default_value(field)
        return [] if field.repeated
        return nil if field.type.is_a?(Message)
        return 0 if field.type.is_a?(Enum)
        case field.type
        when :string then ""
        when :bytes then "".b
        when :bool then false
        when :float, :double then 0.0
        else 0
        end
      end

      def default?(type, value)
        return value.nil? if type.is_a?(Message)
        return value.is_a?(Integer) && value.zero? if type.is_a?(Enum)
        case type
        when :string, :bytes then value == ""
        when :bool then value == false
        when :float, :double then value == 0 && !value.to_s.start_with?("-")
        else value.is_a?(Integer) && value.zero?
        end
      end

      def encode_field(field, value, depth:)
        payload = encode_value(field.type, value, depth:)
        tag = Wire.varint((field.number << 3) | wire_type(field.type))
        wire_type(field.type) == 2 ? tag + Wire.varint(payload.bytesize) + payload : tag + payload
      end

      def bounded(value, bits:, signed:)
        minimum, maximum = signed ? [-(2**(bits - 1)), 2**(bits - 1) - 1] : [0, 2**bits - 1]
        raise InvalidInput, "Protobuf integer is out of range" unless value.is_a?(Integer) && value.between?(minimum, maximum)
        value
      end

      def encode_value(type, value, depth:)
        return type.encode(value, depth: depth + 1) if type.is_a?(Message)
        if type.is_a?(Enum)
          value = type.values.fetch(value) { raise InvalidInput, "Unknown enum symbol" } if value.is_a?(Symbol)
          return Wire.varint(bounded(value, bits: 32, signed: true) & (2**64 - 1))
        end
        case type
        when :string, :bytes
          raise InvalidInput, "Expected a protobuf string" unless value.is_a?(String)
          raise InvalidInput, "Invalid UTF-8 string" if type == :string && !value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          value.b
        when :bool
          raise InvalidInput, "Expected a protobuf boolean" unless value == true || value == false
          Wire.varint(value ? 1 : 0)
        when :float, :double
          raise InvalidInput, "Expected a protobuf number" unless value.is_a?(Numeric)
          [value].pack(type == :float ? "e" : "E")
        else
          bits = type.to_s.end_with?("32") ? 32 : 64
          signed = !%i[uint32 uint64 fixed32 fixed64].include?(type)
          value = bounded(value, bits:, signed:)
          case type
          when :sint32, :sint64 then Wire.varint((value << 1) ^ (value >> (bits - 1)))
          when :fixed32 then [value].pack("V")
          when :sfixed32 then [value].pack("l<")
          when :fixed64 then [value].pack("Q<")
          when :sfixed64 then [value].pack("q<")
          else Wire.varint(value & (2**64 - 1))
          end
        end
      end

      def decode_value(type, cursor, depth:, initial: nil)
        return type.decode(cursor.take(cursor.varint), depth: depth + 1, initial:) if type.is_a?(Message)
        if type.is_a?(Enum)
          value = cursor.varint & (2**32 - 1)
          return value >= 2**31 ? value - 2**32 : value
        end
        case type
        when :string, :bytes
          value = cursor.take(cursor.varint)
          if type == :string
            value.force_encoding(Encoding::UTF_8)
            raise InvalidInput, "Invalid UTF-8 string" unless value.valid_encoding?
          end
          value
        when :bool then !cursor.varint.zero?
        when :float then cursor.take(4).unpack1("e")
        when :double then cursor.take(8).unpack1("E")
        when :fixed32 then cursor.take(4).unpack1("V")
        when :sfixed32 then cursor.take(4).unpack1("l<")
        when :fixed64 then cursor.take(8).unpack1("Q<")
        when :sfixed64 then cursor.take(8).unpack1("q<")
        else
          bits = type.to_s.end_with?("32") ? 32 : 64
          value = cursor.varint & (2**bits - 1)
          return (value >> 1) ^ -(value & 1) if %i[sint32 sint64].include?(type)
          return value - 2**bits if %i[int32 int64].include?(type) && value >= 2**(bits - 1)
          value
        end
      end
    end
  end
end
