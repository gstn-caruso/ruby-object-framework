# frozen_string_literal: true

require "object_framework"
require_relative "support/http_client"

Spec.test "HTTP keep-alive admits a new thread and context for every sequential request" do
  with_http do |app, server|
    client = HTTPClient.new(server.port)
    first = JSON.parse(client.request[:body])
    second = JSON.parse(client.request(headers: { "X-Operation-Id" => "untrusted" })[:body])
    assert first["thread"] != second["thread"]
    assert first["operation_id"] != second["operation_id"]
    assert second["operation_id"] != "untrusted"
  ensure
    client&.close
  end
end

Spec.test "HTTP accepts fragmented requests, chunk extensions, trailers, and pipelined requests" do
  with_http do |app, server|
    client = HTTPClient.new(server.port)
    fragments = ["PO", "ST /items/one HTTP/1.1\r\nHo", "st: localhost\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n", "4;name=value\r\n{\"a\"\r\n", "3\r\n:1}\r\n0\r\nX-Checksum: good\r\n\r\nGET /items/two HTTP/1.1\r\nHost: localhost\r\n\r\n"]
    fragments.each { |fragment| client.send_raw(fragment) }
    assert_equal({ "a" => 1 }, JSON.parse(client.response[:body])["body"])
    assert_equal "two", JSON.parse(client.response[:body])["id"]
  ensure
    client&.close
  end
end

Spec.test "HTTP serves HEAD and OPTIONS and classifies routing and JSON failures" do
  with_http do |app, server|
    client = HTTPClient.new(server.port)
    assert_equal "", client.request("HEAD")[:body]
    options = client.request("OPTIONS")
    assert_equal 204, options[:status]
    assert_equal "GET, HEAD, OPTIONS, POST", options[:headers]["allow"]
    assert_equal 405, client.request("DELETE")[:status]
    assert_equal 404, client.request("GET", "/missing")[:status]
    assert_equal 400, client.request("POST", body: "{", headers: { "Content-Type" => "application/json" })[:status]
    assert_equal 422, client.request("POST", body: "[]", headers: { "Content-Type" => "application/json" })[:status]
  ensure
    client&.close
  end
end

Spec.test "HTTP framing errors close the connection without executing a pipelined request" do
  calls = []
  with_http(controller: ->(input, context:) { calls << true; {} }) do |app, server|
    client = HTTPClient.new(server.port)
    client.send_raw("POST /items/one HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /items/two HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_equal 400, client.response[:status]
    assert client.eof?
    assert_equal [], calls
  ensure
    client&.close
  end
end

Spec.test "HTTP saturation returns 503 before creating an additional request thread" do
  with_http(max_requests: 1) do |app, server|
    first, excess = HTTPClient.new(server.port), HTTPClient.new(server.port)
    first.send_raw("POST /items/one HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n")
    wait_until { server.active_count == 1 }
    assert_equal 503, excess.request[:status]
    assert_equal 1, server.admitted_count
    first.send_raw("{}")
    assert_equal 200, first.response[:status]
  ensure
    first&.close
    excess&.close
  end
end

Spec.test "HTTP header, body, execution, and idle deadlines release connections" do
  with_http(header_timeout: 0.05, body_timeout: 0.05, idle_timeout: 0.05) do |app, server|
    slow = HTTPClient.new(server.port)
    slow.send_raw("GET /items/one HTTP/1.1\r\n")
    assert_equal 408, slow.response[:status]
    body = HTTPClient.new(server.port)
    body.send_raw("POST /items/one HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n")
    assert_equal 408, body.response[:status]
    idle = HTTPClient.new(server.port)
    assert_equal 200, idle.request[:status]
    assert idle.eof?
  ensure
    [slow, body, idle].compact.each(&:close)
  end
  controller = ->(input, context:) { sleep 0.07; context.cancellation.check!; {} }
  with_http(controller:, execution_timeout: 0.05) do |app, server|
    client = HTTPClient.new(server.port)
    assert_equal 503, client.request[:status]
  ensure
    client&.close
  end
end

Spec.test "HTTP unexpected failures are generic public problems with a single diagnostic" do
  records = []
  controller = ->(input, context:) { raise "password=secret" }
  with_http(controller:, records:) do |app, server|
    client = HTTPClient.new(server.port)
    response = client.request
    assert_equal 500, response[:status]
    assert_equal "application/problem+json", response[:headers]["content-type"]
    problem = JSON.parse(response[:body])
    assert_equal "internal_error", problem["code"]
    assert_equal "urn:uuid:#{problem['operation_id']}", problem["instance"]
    assert !response[:body].include?("secret")
    assert_equal 1, records.size
  ensure
    client&.close
  end
end

Spec.test "HTTP has a predefined fallback when error presentation fails" do
  failing = Object.new
  failing.define_singleton_method(:call) { |exception, context:| raise "presenter failed" }
  with_http(controller: ->(input, context:) { raise "controller failed" }, problem_presenter: failing) do |app, server|
    client = HTTPClient.new(server.port)
    assert_equal 500, client.request[:status]
  ensure
    client&.close
  end
end

Spec.test "HTTP releases connections and admission even when writer construction fails" do
  factory = ->(reader) { raise "writer unavailable" }
  with_http(writer_factory: factory) do |app, server|
    client = HTTPClient.new(server.port)
    assert_equal 500, client.request[:status]
    wait_until { server.active_count.zero? }
    client.close
    wait_until { server.connection_count.zero? }
  ensure
    client&.close
  end
end

Spec.test "HTTP detects premature body EOF and classifies it as malformed input" do
  with_http do |app, server|
    client = HTTPClient.new(server.port)
    client.send_raw("POST /items/one HTTP/1.1\r\nHost: localhost\r\nContent-Length: 20\r\n\r\n{")
    client.socket.shutdown(Socket::SHUT_WR)
    assert_equal 400, client.response[:status]
  ensure
    client&.close
  end
end

Spec.test "HTTP TLS uses application-provided certificates" do
  key = OpenSSL::PKey::RSA.new(2048)
  certificate = OpenSSL::X509::Certificate.new
  certificate.version, certificate.serial = 2, 1
  certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
  certificate.public_key = key.public_key
  certificate.not_before, certificate.not_after = Time.now - 60, Time.now + 3600
  certificate.sign(key, OpenSSL::Digest.new("SHA256"))
  tls = OpenSSL::SSL::SSLContext.new
  tls.cert, tls.key = certificate, key
  with_http(tls_context: tls) do |app, server|
    tcp = TCPSocket.new("127.0.0.1", server.port)
    client_tls = OpenSSL::SSL::SSLContext.new
    client_tls.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, client_tls)
    ssl.sync_close = true
    ssl.connect
    client = HTTPClient.new(server.port, socket: ssl)
    assert_equal 200, client.request[:status]
  ensure
    client&.close
    tcp&.close unless tcp&.closed?
  end
end

Spec.test "HTTP presentation failures after commit retain the committed outcome" do
  storage = ObjectFramework::Memory::Storage.new
  use_case = Class.new do
    def initialize(transaction:); @transaction = transaction; end
    def call; @transaction.insert(:records, { id: "committed" }); { ok: true }; end
  end
  records = []
  errors = ObjectFramework::ErrorRegistry.new
  reporter = ObjectFramework::FailureReporter.new(registry: errors, sink: ->(record) { records << record })
  app = ObjectFramework::Application.new(storage:, errors:, reporter:)
  app.operation(:write, use_case:, policy: :write, dependencies: [:transaction])
  router = ObjectFramework::HTTP::Router.new
  router.controller(:write, ObjectFramework::HTTP::Controller.new(application: app, operation: :write))
  router.route("POST", "/write", controller: :write)
  presenter = ->(result) { raise "late presentation failure" }
  server = ObjectFramework::HTTP::Server.new(application: app, router:, presenter:)
  app.install(server)
  app.start
  client = HTTPClient.new(server.port)
  assert_equal 500, client.request("POST", "/write")[:status]
  assert_equal :committed, records.first[:transaction_state]
  check = storage.begin_transaction(mode: :read)
  assert_equal "committed", check.find(:records, "committed")[:id]
ensure
  client&.close
  app&.stop
  check&.close
  storage&.close
end

Spec.test "HTTP closes the connection when response sending fails after bytes were sent" do
  writer = Class.new do
    attr_reader :started
    def initialize(reader); @reader, @started = reader, false; end
    def call(response, **options)
      @reader.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{", deadline: options[:deadline]) { @started = true }
      raise IOError, "send failure"
    end
  end
  records = []
  with_http(writer_factory: ->(reader) { writer.new(reader) }, records:) do |app, server|
    client = HTTPClient.new(server.port)
    assert_raises(EOFError) { client.request }
    assert_equal 1, records.size
    wait_until { server.active_count.zero? }
  ensure
    client&.close
  end
end

Spec.test "HTTP interoperates with the independent standard-library Net::HTTP client" do
  require "net/http"
  with_http do |app, server|
    http = Net::HTTP.new("127.0.0.1", server.port, nil)
    response = http.get("/items/independent")
    assert_equal "200", response.code
    assert_equal "independent", JSON.parse(response.body)["id"]
  end
end

Spec.test "HTTP rejects TLS configuration without application certificates before binding" do
  assert_raises(ObjectFramework::ConfigurationError) do
    with_http(tls_context: OpenSSL::SSL::SSLContext.new) { raise "Unexpected listener" }
  end
end

Spec.test "HTTP writers replace framing headers case-insensitively" do
  bytes = +""
  reader = Object.new
  reader.define_singleton_method(:write) { |data, deadline:, &block| bytes << data; block.call(data.bytesize) }
  response = ObjectFramework::HTTP::Response.new(status: 200, headers: { "content-length" => "999", "connection" => "close" }, body: "{}")
  ObjectFramework::HTTP::Writer.new(reader:).call(response, deadline: ObjectFramework::HTTP::Timing.now + 1)
  assert_equal 1, bytes.scan(/^content-length:/i).size
  assert_equal 1, bytes.scan(/^connection:/i).size
  assert bytes.include?("Content-Length: 2\r\n")
end
