# frozen_string_literal: true

require "net/http"
require "json"
require_relative "../orders/application"

bundle = OrdersExample.build
bundle.application.start
begin
  http = Net::HTTP.new("127.0.0.1", bundle.server.port, nil)
  response = http.post("/orders/ready/confirm", "")
  puts "HTTP #{response.code}"
  puts "Order state: #{JSON.parse(response.body).fetch('state')}"
ensure
  bundle.application.stop
  bundle.storage.close
end
