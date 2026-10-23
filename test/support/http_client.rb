# frozen_string_literal: true

require "socket"

class HTTPClient
  attr_reader :socket

  def initialize(port, socket: nil)
    @socket = socket || TCPSocket.new("127.0.0.1", port)
    @buffer = +"".b
  end

  def send_raw(bytes)
    @socket.write(bytes)
  end

  def request(method = "GET", path = "/items/one", body: "", headers: {})
    fields = { "Host" => "localhost", "Content-Length" => body.bytesize.to_s }.merge(headers)
    send_raw("#{method} #{path} HTTP/1.1\r\n#{fields.map { |key, value| "#{key}: #{value}\r\n" }.join}\r\n#{body}")
    response(head: method == "HEAD")
  end

  def response(head: false)
    until (index = @buffer.index("\r\n\r\n"))
      @buffer << receive
    end
    raw = @buffer.slice!(0, index + 4)
    lines = raw.split("\r\n")
    status = Integer(lines.shift.split(" ")[1])
    headers = lines.to_h { |line| key, value = line.split(":", 2); [key.downcase, value.strip] }
    length = head || status < 200 || [204, 304].include?(status) ? 0 : Integer(headers.fetch("content-length"))
    @buffer << receive while @buffer.bytesize < length
    { status:, headers:, body: @buffer.slice!(0, length) }
  end

  def eof?
    receive
    false
  rescue EOFError
    true
  end

  def close
    @socket.close unless @socket.closed?
  end

  private

  def receive
    raise "HTTP client timed out" unless IO.select([@socket], nil, nil, 3)
    @socket.readpartial(16_384)
  end
end

module HTTPFixture
  def with_http(controller: nil, records: [], **options)
    registry = ObjectFramework::ErrorRegistry.new
    reporter = ObjectFramework::FailureReporter.new(registry:, sink: ->(record) { records << record })
    app = ObjectFramework::Application.new(errors: registry, reporter:)
    router = ObjectFramework::HTTP::Router.new
    controller ||= ->(input, context:) { { id: input.params[:id], body: input.body, thread: Thread.current.object_id, operation_id: context.operation_id } }
    router.controller(:items, controller)
    %w[GET POST].each { |method| router.route(method, "/items/:id", controller: :items) }
    server = ObjectFramework::HTTP::Server.new(application: app, router:, **options)
    app.install(server)
    app.start
    yield app, server
  ensure
    app&.stop
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until yield
      raise "Condition timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end
  end
end
Spec::Assertions.include(HTTPFixture)
