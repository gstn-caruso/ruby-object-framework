# frozen_string_literal: true

require "net/http"
require "json"
require_relative "../orders/application"

bundle = OrdersExample.build
bundle.application.start
begin
  http = Net::HTTP.new("127.0.0.1", bundle.server.port, nil)
  %w[missing rejected].each do |id|
    response = http.post("/orders/#{id}/confirm", "")
    problem = JSON.parse(response.body)
    puts "#{response.code} #{problem.fetch('code')}"
    puts "Occurrence ID present: #{problem.key?('operation_id')}"
  end
ensure
  bundle.application.stop
  bundle.storage.close
end
