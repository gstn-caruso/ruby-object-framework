# frozen_string_literal: true

require_relative "application"

bundle = OrdersExample.build(port: Integer(ENV.fetch("PORT", "8080")))
bundle.application.start
puts "Order confirmation API: http://127.0.0.1:#{bundle.server.port}"
puts "POST /orders/ready/confirm; POST /orders/rejected/confirm"

# Signal handlers only wake the main thread; resource cleanup stays in normal Ruby code.
signals = Queue.new
%w[INT TERM].each { |signal| Signal.trap(signal) { signals << signal } }
begin
  signals.pop
ensure
  bundle.application.stop
  bundle.storage.close
end
