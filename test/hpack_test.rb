# frozen_string_literal: true

require "object_framework"

Spec.test "HPACK decodes RFC request vectors with dynamic indexing" do
  decoder = ObjectFramework::HTTP2::HPACK::Decoder.new
  first = ["828684410f7777772e6578616d706c652e636f6d"].pack("H*")
  assert_equal [[":method", "GET"], [":scheme", "http"], [":path", "/"], [":authority", "www.example.com"]], decoder.decode(first)
  second = ["828684be58086e6f2d6361636865"].pack("H*")
  assert_equal ["cache-control", "no-cache"], decoder.decode(second).last
end

Spec.test "HPACK Huffman coding follows RFC vectors and rejects invalid padding and EOS" do
  huffman = ObjectFramework::HTTP2::HPACK::Huffman
  assert_equal "f1e3c2e5f23a6ba0ab90f4ff", huffman.encode("www.example.com").unpack1("H*")
  assert_equal "www.example.com", huffman.decode(["f1e3c2e5f23a6ba0ab90f4ff"].pack("H*"))
  ["ff", "ffffffff", "00"].each do |hex|
    assert_raises(ObjectFramework::HTTP2::CompressionError) { huffman.decode([hex].pack("H*")) }
  end
  decoder = ObjectFramework::HTTP2::HPACK::Decoder.new
  headers = decoder.decode(["828684418cf1e3c2e5f23a6ba0ab90f4ff"].pack("H*"))
  assert_equal [":authority", "www.example.com"], headers.last
end

Spec.test "HPACK handles table-size eviction, limits, malformed indices, and literal fields" do
  encoder = ObjectFramework::HTTP2::HPACK::Encoder.new
  headers = [[":status", "200"], ["content-type", "application/grpc"], ["grpc-status", "0"]]
  decoder = ObjectFramework::HTTP2::HPACK::Decoder.new
  assert_equal headers, decoder.decode(encoder.encode(headers))
  assert_raises(ObjectFramework::HTTP2::CompressionError) { decoder.decode("\x80".b) }
  assert_raises(ObjectFramework::HTTP2::CompressionError) { decoder.decode("\x3f\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7f".b) }
  assert_raises(ObjectFramework::HTTP2::CompressionError) { decoder.decode("\x82\x20".b) }
  limited = ObjectFramework::HTTP2::HPACK::Decoder.new(header_limit: 40)
  assert_raises(ObjectFramework::HTTP2::CompressionError) { limited.decode(encoder.encode([["long-name", "x" * 50]])) }
end
