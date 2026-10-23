# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../orders/application"
require_relative "../orders/contracts"

bundle = OrdersExample.build
service = OrdersExample.grpc_contract
controller = ObjectFramework::GRPC::Controller.new(application: bundle.application, operation: :confirm_order)
server = ObjectFramework::GRPC::Server.new(application: bundle.application, services: [service], controllers: { confirm_order: controller })
bundle.application.install(server)
bundle.application.start
begin
  Dir.mktmpdir("orders-grpc-guide") do |directory|
    contract = File.join(directory, "orders.proto")
    File.write(contract, service.to_proto)
    python = ENV.fetch("OBJECT_FRAMEWORK_INTEROP_PYTHON", File.expand_path("../../.venv/bin/python", __dir__))
    output, error, status = Open3.capture3(python, File.expand_path("../orders/grpc_client.py", __dir__), server.port.to_s, contract, "ready")
    raise error unless status.success?
    print output
  end
ensure
  bundle.application.stop
  bundle.storage.close
end
