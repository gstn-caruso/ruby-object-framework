# frozen_string_literal: true

require "object_framework"

Spec.test "Protocol Buffers encode proto3 scalar wire types and default values" do
  descriptor = ObjectFramework::Protobuf::Message.new("Scalar") do
    field :number, 1, :int32
    field :signed, 2, :sint64
    field :name, 3, :string
    field :active, 4, :bool
    field :ratio, 5, :double
    field :bytes, 6, :bytes
    field :fixed, 7, :fixed32
  end
  assert_equal [8, 150, 1], descriptor.encode(number: 150).bytes
  input = { number: -15, signed: -300, name: "Ada", active: true, ratio: 1.5, bytes: "\x00\xff".b, fixed: 123 }
  assert_equal input, descriptor.decode(descriptor.encode(input))
  assert_equal 0, descriptor.decode("")[:number]
  assert_equal false, descriptor.decode("")[:active]
end

Spec.test "Protocol Buffers support enums, nested messages, and packed or unpacked repeated values" do
  state = ObjectFramework::Protobuf::Enum.new("State", UNKNOWN: 0, READY: 1)
  nested = ObjectFramework::Protobuf::Message.new("Nested") { field :name, 1, :string }
  descriptor = ObjectFramework::Protobuf::Message.new("Container") do
    field :state, 1, state
    field :nested, 2, nested
    field :values, 3, :int32, repeated: true
    field :names, 4, :string, repeated: true
  end
  input = { state: 1, nested: { name: "Ada" }, values: [1, 2, 300], names: ["a", "b"] }
  assert_equal input, descriptor.decode(descriptor.encode(input))
  assert_equal [1, 2], descriptor.decode([24, 1, 24, 2].pack("C*"))[:values]
  assert_equal 91, descriptor.decode([8, 91].pack("C*"))[:state]
end

Spec.test "Protocol Buffers reject truncation and overflow and skip unknown fields" do
  descriptor = ObjectFramework::Protobuf::Message.new("Known") { field :id, 1, :uint64 }
  assert_equal({ id: 5 }, descriptor.decode([8, 5, 18, 2, 65, 66].pack("C*")))
  ["\x80".b, "\x0a\x10x".b, "\x08".b + "\xff".b * 11, "\x00".b].each do |bytes|
    assert_raises(ObjectFramework::InvalidInput) { descriptor.decode(bytes) }
  end
  assert_raises(ObjectFramework::InvalidInput) { descriptor.encode(id: -1) }
end

Spec.test "Protocol Buffers export complete proto3 contracts from Ruby descriptors" do
  request = ObjectFramework::Protobuf::Message.new("Request") { field :name, 1, :string }
  response = ObjectFramework::Protobuf::Message.new("Reply") { field :name, 1, :string }
  service = ObjectFramework::GRPC::Service.new("example.Greeter")
  service.rpc(:Hello, input: request, output: response, controller: :hello)
  proto = service.to_proto
  assert proto.include?('syntax = "proto3";')
  assert proto.include?("package example;")
  assert proto.include?("string name = 1;")
  assert proto.include?("rpc Hello (Request) returns (Reply);")
end
