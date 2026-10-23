# frozen_string_literal: true

require "object_framework"

Spec.test "HTTP parses origin and absolute targets with strict request framing" do
  parser = ObjectFramework::HTTP::Parser.new
  head = parser.parse_head("POST /orders/one?confirm=true HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n")
  assert_equal "/orders/one", head.path
  assert_equal "confirm=true", head.query
  assert_equal 2, head.length
  assert head.keep_alive
  head = parser.parse_head("GET http://example.test/items HTTP/1.1\r\nHost: ignored.test\r\nConnection: close\r\n\r\n")
  assert_equal "/items", head.path
  assert !head.keep_alive
end

Spec.test "HTTP rejects ambiguous framing, malformed headers, and invalid hosts" do
  parser = ObjectFramework::HTTP::Parser.new
  invalid = [
    "Content-Length: 1\r\nTransfer-Encoding: chunked",
    "Content-Length: 1\r\nContent-Length: 1",
    "Content-Length: 1, 2", "Content-Length: -1",
    "Transfer-Encoding: chunked, chunked", "Host: second.test",
    " Content-Length: 1", "Content-Length : 1", "X-Bad: value\x00"
  ]
  invalid.each do |headers|
    assert_raises(ObjectFramework::HTTP::BadRequest) do
      parser.parse_head("POST / HTTP/1.1\r\nHost: localhost\r\n#{headers}\r\n\r\n")
    end
  end
  assert_raises(ObjectFramework::HTTP::BadRequest) { parser.parse_head("GET / HTTP/1.1\r\n\r\n") }
  assert_raises(ObjectFramework::HTTP::BadRequest) { parser.parse_head("GET / HTTP/1.1\nHost: localhost\n\n") }
end

Spec.test "HTTP enforces configurable request-line, header, and body limits" do
  parser = ObjectFramework::HTTP::Parser.new(line_limit: 30, header_limit: 40, body_limit: 4)
  assert_raises(ObjectFramework::HTTP::URITooLong) { parser.parse_head("GET /#{'x' * 30} HTTP/1.1\r\nHost: test\r\n\r\n") }
  assert_raises(ObjectFramework::HTTP::HeadersTooLarge) { parser.parse_head("GET / HTTP/1.1\r\nHost: test\r\nX-Long: #{'x' * 40}\r\n\r\n") }
  assert_raises(ObjectFramework::HTTP::PayloadTooLarge) { parser.parse_head("POST / HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\n") }
end

Spec.test "HTTP routing validates bindings and supplies 404, 405, HEAD, and OPTIONS" do
  router = ObjectFramework::HTTP::Router.new
  controller = ->(input, context:) { nil }
  router.controller(:items, controller)
  router.route("GET", "/items/:id", controller: :items)
  router.validate!
  match = router.resolve("GET", "/items/a%20b")
  assert_same controller, match.controller
  assert_equal({ id: "a b" }, match.params)
  assert_same controller, router.resolve("HEAD", "/items/a").controller
  assert_equal ["GET", "HEAD", "OPTIONS"], router.resolve("OPTIONS", "/items/a").allow
  failure = assert_raises(ObjectFramework::HTTP::MethodNotAllowed) { router.resolve("POST", "/items/a") }
  assert_equal "GET, HEAD, OPTIONS", failure.headers["Allow"]
  assert_raises(ObjectFramework::NotFound) { router.resolve("GET", "/missing") }
  missing = ObjectFramework::HTTP::Router.new
  missing.route("GET", "/", controller: :missing)
  assert_raises(ObjectFramework::ConfigurationError) { missing.validate! }
end

Spec.test "HTTP JSON decoding and declared parameters distinguish syntax and structural errors" do
  decoder = ObjectFramework::HTTP::JSONDecoder.new
  assert_raises(ObjectFramework::HTTP::BadRequest) { decoder.call("{", content_type: "application/json") }
  assert_raises(ObjectFramework::InvalidInput) { decoder.call("[]", content_type: "application/json") }
  assert_raises(ObjectFramework::HTTP::UnsupportedMediaType) { decoder.call("{}", content_type: "text/plain") }
  parameters = ObjectFramework::HTTP::Parameters.new do
    field :id, source: :path, type: String
    field :quantity, source: :body, type: Integer
  end
  input = ObjectFramework::HTTP::Input.new(params: { id: "order" }, query: {}, body: { "quantity" => 2 })
  assert_equal({ id: "order", quantity: 2 }, parameters.normalize(input))
  bad = ObjectFramework::HTTP::Input.new(params: { id: "order" }, query: {}, body: { "quantity" => "two" })
  assert_raises(ObjectFramework::InvalidInput) { parameters.normalize(bad) }
end
