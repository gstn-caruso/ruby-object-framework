# frozen_string_literal: true

require "object_framework"
require "open3"
require "tmpdir"
require_relative "support/http_client"
require_relative "support/grpc_fixture"

Spec.test "native gRPC interoperates with grpcio for unary, all streaming modes, flow control, and failures" do
  request = ObjectFramework::Protobuf::Message.new("Request") { field :text, 1, :string; field :number, 2, :int32 }
  reply = ObjectFramework::Protobuf::Message.new("Reply") do
    field :text, 1, :string
    field :number, 2, :int32
    field :thread, 3, :uint64
    field :operation_id, 4, :string
  end
  echo = Class.new do
    def initialize(context:); @context = context; end
    def call(text:, number:)
      { text:, number:, thread: Thread.current.object_id, operation_id: @context.operation_id }
    end
  end
  records = []
  registry = ObjectFramework::ErrorRegistry.new
  reporter = ObjectFramework::FailureReporter.new(registry:, sink: ->(record) { records << record })
  app = ObjectFramework::Application.new(errors: registry, reporter:)
  app.operation(:echo, use_case: echo, policy: :none, dependencies: [:context])
  controllers = {
    echo: ObjectFramework::GRPC::Controller.new(application: app, operation: :echo),
    expand: ->(input, context:) { input[:number].times.lazy.map { |index| { number: index } } },
    collect: ->(input, context:) { { number: input.sum { |message| message[:number] } } },
    chat: ->(input, context:) { input.lazy.map { |message| { text: message[:text].upcase } } },
    fail: ->(input, context:) { raise "password=secret" },
    absent: ->(input, context:) { raise ObjectFramework::NotFound },
    slow: ->(input, context:) { loop { context.cancellation.check!; sleep 0.005 } },
    late: ->(input, context:) { Enumerator.new { |output| output << { text: "before failure" }; raise "password=secret" } }
  }
  service = ObjectFramework::GRPC::Service.new("interop.Test")
  service.rpc(:Echo, input: request, output: reply, controller: :echo)
  service.rpc(:Expand, input: request, output: reply, controller: :expand, server_streaming: true)
  service.rpc(:Collect, input: request, output: reply, controller: :collect, client_streaming: true)
  service.rpc(:Chat, input: request, output: reply, controller: :chat, client_streaming: true, server_streaming: true)
  %i[Fail Absent Slow Late].each do |name|
    service.rpc(name, input: request, output: reply, controller: name.to_s.downcase.to_sym, server_streaming: name == :Late)
  end
  server = ObjectFramework::GRPC::Server.new(application: app, services: [service], controllers:)
  app.install(server)
  app.start
  Dir.mktmpdir("object-framework-interop") do |directory|
    proto_path = File.join(directory, "interop.proto")
    File.write(proto_path, service.to_proto)
    python = ENV.fetch("OBJECT_FRAMEWORK_INTEROP_PYTHON", File.expand_path("../.venv/bin/python", __dir__))
    stdout, stderr, status = Open3.capture3(python, File.join(__dir__, "interop/grpc_client.py"), server.port.to_s, proto_path)
    assert status.success?, "Independent gRPC client failed:\n#{stdout}\n#{stderr}"
    assert JSON.parse(stdout).values.all?
  end
  wait_until { server.active_count.zero? }
  assert records.any? { |record| record[:code] == "internal_error" }
  assert records.none? { |record| record.inspect.include?("password=secret") }
ensure
  app&.stop
end

Spec.test "gRPC TLS negotiates h2 and interoperates with a certificate-verifying client" do
  context, certificate = test_certificate
  with_grpc(tls_context: context) do |app, server, service|
    grpc_client(server, service, scenario: "tls", certificate:)
    wait_until { server.active_count.zero? }
  end
end

Spec.test "gRPC admission is bounded across connections without starting another RPC thread" do
  with_grpc(max_requests: 1) do |app, server, service|
    grpc_client(server, service, scenario: "capacity")
    wait_until { server.active_count.zero? }
  end
end

Spec.test "gRPC streaming commits per-message use cases and retains effects after a late failure" do
  storage = ObjectFramework::Memory::Storage.new
  app = ObjectFramework::Application.new(storage:)
  use_case = Class.new do
    def initialize(transaction:); @transaction = transaction; end
    def call(text:, number:)
      @transaction.insert(:messages, { id: text, text: })
      { text: text.upcase }
    end
  end
  app.operation(:append, use_case:, policy: :write, dependencies: [:transaction])
  controller = ->(input, context:) do
    Enumerator.new do |output|
      input.each { |message| output << app.invoke(:append, context:, **message) }
      raise "late stream failure"
    end
  end
  with_grpc(app:, controllers: { chat: controller }) do |application, server, service|
    grpc_client(server, service, scenario: "transactions")
    read = storage.begin_transaction(mode: :read)
    rows = read.query(ObjectFramework::Persistence::Query.new(table: :messages))
    assert_equal ["a", "b"], rows.map { |row| row[:id] }
    read.close
  end
ensure
  storage&.close
end

Spec.test "HTTP2 interoperates with hyper-h2 for continuations, flow control, and isolated stream errors" do
  with_grpc do |app, server, service|
    grpc_client(server, service, script: "h2_client.py")
    wait_until { server.active_count.zero? }
  end
end
