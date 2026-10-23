# frozen_string_literal: true

require_relative "application"
require_relative "contracts"

bundle = OrdersExample.build(port: Integer(ENV.fetch("HTTP_PORT", "8080")))
controller = ObjectFramework::GRPC::Controller.new(application: bundle.application, operation: :confirm_order)
grpc = ObjectFramework::GRPC::Server.new(application: bundle.application,
  services: [OrdersExample.grpc_contract], controllers: { confirm_order: controller },
  port: Integer(ENV.fetch("GRPC_PORT", "50051")))
bundle.application.install(grpc)
bundle.application.start
puts "HTTP order API: http://127.0.0.1:#{bundle.server.port}"
puts "gRPC order API: 127.0.0.1:#{grpc.port} (orders.Orders/ConfirmOrder)"

signals = Queue.new
%w[INT TERM].each { |signal| Signal.trap(signal) { signals << signal } }
begin
  signals.pop
ensure
  bundle.application.stop
  bundle.storage.close
end
