# frozen_string_literal: true

module ObjectFramework
  module HTTP2
    Frame = Data.define(:type, :flags, :stream_id, :payload) do
      def encode
        raise ProtocolError, "Frame is too large" if payload.bytesize > 16_777_215
        length = [payload.bytesize].pack("N").byteslice(1, 3)
        length + [type, flags, stream_id & 0x7fff_ffff].pack("CCN") + payload.b
      end

      def self.read(reader, deadline:, max_size: 16_384)
        header = reader.read_exact(9, deadline:)
        length = ("\x00".b + header.byteslice(0, 3)).unpack1("N")
        raise ProtocolError.new("Frame exceeds advertised size", code: 6) if length > max_size
        type, flags, stream_id = header.byteslice(3, 6).unpack("CCN")
        new(type:, flags:, stream_id: stream_id & 0x7fff_ffff, payload: reader.read_exact(length, deadline:))
      end
    end
  end
end
