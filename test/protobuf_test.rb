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

Spec.test "Protocol Buffers agree with Google's codec for every scalar, enums, and nested repeated values" do
  require "base64"
  require "open3"
  require "tmpdir"
  state = ObjectFramework::Protobuf::Enum.new("State", UNKNOWN: 0, READY: 1)
  nested = ObjectFramework::Protobuf::Message.new("Nested") { field :name, 1, :string }
  values = {
    int32_value: -(2**31), int64_value: -(2**63), uint32_value: 2**32 - 1,
    uint64_value: 2**64 - 1, sint32_value: -123, sint64_value: -456,
    fixed32_value: 2**32 - 1, fixed64_value: 2**64 - 1, sfixed32_value: -123,
    sfixed64_value: -456, float_value: 1.5, double_value: -2.5, bool_value: true,
    string_value: "Hello λ", bytes_value: "\x00\xff".b, state: 1,
    values: [-1, 0, 1], nested: { name: "Ada" }
  }
  descriptor = ObjectFramework::Protobuf::Message.new("Everything") do
    ObjectFramework::Protobuf::SCALARS.keys.each_with_index { |type, index| field "#{type}_value", index + 1, type }
    field :state, 16, state
    field :values, 17, :int32, repeated: true
    field :nested, 18, nested
  end
  service = ObjectFramework::GRPC::Service.new("interop.Scalars")
  service.rpc(:Echo, input: descriptor, output: descriptor, controller: :echo)
  Dir.mktmpdir("object-framework-scalars") do |directory|
    path = File.join(directory, "scalars.proto")
    File.write(path, service.to_proto)
    python = ENV.fetch("OBJECT_FRAMEWORK_INTEROP_PYTHON", File.expand_path("../.venv/bin/python", __dir__))
    output, error, status = Open3.capture3(python, File.join(__dir__, "interop/protobuf_client.py"), path, Base64.strict_encode64(descriptor.encode(values)))
    assert status.success?, error
    assert_equal values, descriptor.decode(Base64.strict_decode64(JSON.parse(output).fetch("encoded")))
  end
end

Spec.test "Protocol Buffers reject incorrect integer zero types and ambiguous exported contracts" do
  first = ObjectFramework::Protobuf::Message.new("Same") { field :id, 1, :int32 }
  second = ObjectFramework::Protobuf::Message.new("Same") { field :name, 1, :string }
  assert_raises(ObjectFramework::InvalidInput) { first.encode(id: 0.0) }
  service = ObjectFramework::GRPC::Service.new("interop.Ambiguous")
  service.rpc(:Call, input: first, output: second, controller: :call)
  assert_raises(ObjectFramework::ConfigurationError) { service.to_proto }
end
