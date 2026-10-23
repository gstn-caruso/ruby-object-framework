# frozen_string_literal: true

require_relative "contracts"

puts OrdersExample.grpc_contract.to_proto
