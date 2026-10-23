# frozen_string_literal: true

require "object_framework"

Spec.test "HTTP/2 frames preserve 24-bit lengths, flags, and stream identities" do
  frame = ObjectFramework::HTTP2::Frame.new(type: 0, flags: 1, stream_id: 3, payload: "hello")
  assert_equal [0, 0, 5, 0, 1, 0, 0, 0, 3], frame.encode.bytes.first(9)
  reader = Object.new
  bytes = frame.encode
  reader.define_singleton_method(:read_exact) { |length, deadline:| bytes.slice!(0, length) }
  parsed = ObjectFramework::HTTP2::Frame.read(reader, deadline: 1)
  assert_equal frame, parsed
  bytes = [0, 64, 1, 0, 0, 0, 0, 0, 1].pack("C*")
  assert_raises(ObjectFramework::HTTP2::ProtocolError) { ObjectFramework::HTTP2::Frame.read(reader, deadline: 1) }
end

Spec.test "gRPC message framing supports fragmented input and enforces declared lengths" do
  descriptor = ObjectFramework::Protobuf::Message.new("Item") { field :name, 1, :string }
  encoded = ObjectFramework::GRPC::Messages.frame(descriptor.encode(name: "Ada"))
  input = ObjectFramework::HTTP2::Inbound.new(cancellation: ObjectFramework::Cancellation.new)
  encoded.bytes.each { |byte| input.push([byte].pack("C")) }
  input.finish
  messages = ObjectFramework::GRPC::Messages.new(input:, descriptor:)
  assert_equal [{ name: "Ada" }], messages.to_a
  input = ObjectFramework::HTTP2::Inbound.new(cancellation: ObjectFramework::Cancellation.new)
  input.push("\x00\x00\x00\x00\x09x".b)
  input.finish
  assert_raises(ObjectFramework::InvalidInput) { ObjectFramework::GRPC::Messages.new(input:, descriptor:).to_a }
end

Spec.test "gRPC stream input releases consumed flow-control capacity and cooperatively cancels" do
  consumed = []
  cancellation = ObjectFramework::Cancellation.new
  input = ObjectFramework::HTTP2::Inbound.new(cancellation:, on_consume: ->(count) { consumed << count })
  input.push("abcdef")
  assert_equal "abc", input.read_exact(3)
  assert_equal 3, consumed.sum
  cancellation.cancel
  assert_raises(ObjectFramework::Cancelled) { input.read_exact(10) }
end
