# frozen_string_literal: true

require "open3"
require "tmpdir"

module GRPCFixture
  def with_grpc(app: nil, controllers: {}, records: [], **options)
    request = ObjectFramework::Protobuf::Message.new("Request") { field :text, 1, :string; field :number, 2, :int32 }
    reply = ObjectFramework::Protobuf::Message.new("Reply") do
      field :text, 1, :string
      field :number, 2, :int32
      field :thread, 3, :uint64
      field :operation_id, 4, :string
    end
    registry = ObjectFramework::ErrorRegistry.new
    reporter = ObjectFramework::FailureReporter.new(registry:, sink: ->(record) { records << record })
    app ||= ObjectFramework::Application.new(errors: registry, reporter:)
    defaults = {
      echo: ->(input, context:) { input.merge(thread: Thread.current.object_id, operation_id: context.operation_id) },
      expand: ->(input, context:) { input[:number].times.lazy.map { |index| { number: index } } },
      collect: ->(input, context:) { { number: input.sum { |message| message[:number] } } },
      chat: ->(input, context:) { input.lazy.map { |message| { text: message[:text].upcase } } },
      fail: ->(input, context:) { raise "password=secret" },
      absent: ->(input, context:) { raise ObjectFramework::NotFound },
      slow: ->(input, context:) { loop { context.cancellation.check!; sleep 0.005 } },
      late: ->(input, context:) { Enumerator.new { |output| output << { text: "before failure" }; raise "password=secret" } }
    }
    controllers = defaults.merge(controllers)
    service = ObjectFramework::GRPC::Service.new("interop.Test")
    service.rpc(:Echo, input: request, output: reply, controller: :echo)
    service.rpc(:Expand, input: request, output: reply, controller: :expand, server_streaming: true)
    service.rpc(:Collect, input: request, output: reply, controller: :collect, client_streaming: true)
    service.rpc(:Chat, input: request, output: reply, controller: :chat, client_streaming: true, server_streaming: true)
    %i[Fail Absent Slow Late].each do |name|
      service.rpc(name, input: request, output: reply, controller: name.to_s.downcase.to_sym, server_streaming: name == :Late)
    end
    server = ObjectFramework::GRPC::Server.new(application: app, services: [service], controllers:, **options)
    app.install(server)
    app.start
    yield app, server, service
  ensure
    app&.stop
  end

  def grpc_client(server, service, scenario: "all", certificate: nil, script: "grpc_client.py")
    Dir.mktmpdir("object-framework-interop") do |directory|
      proto_path = File.join(directory, "interop.proto")
      File.write(proto_path, service.to_proto)
      python = ENV.fetch("OBJECT_FRAMEWORK_INTEROP_PYTHON", File.expand_path("../../.venv/bin/python", __dir__))
      arguments = [python, File.expand_path("../interop/#{script}", __dir__), server.port.to_s, proto_path, scenario]
      if certificate
        certificate_path = File.join(directory, "certificate.pem")
        File.write(certificate_path, certificate.to_pem)
        arguments << certificate_path
      end
      stdout, stderr, status = Open3.capture3(*arguments)
      assert status.success?, "Independent client failed:\n#{stdout}\n#{stderr}"
      assert JSON.parse(stdout).values.all?
    end
  end

  def test_certificate
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version, certificate.serial = 2, 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
    certificate.public_key = key.public_key
    certificate.not_before, certificate.not_after = Time.now - 60, Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = extensions.issuer_certificate = certificate
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
    certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost"))
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = certificate, key
    [context, certificate]
  end
end
Spec::Assertions.include(GRPCFixture)
