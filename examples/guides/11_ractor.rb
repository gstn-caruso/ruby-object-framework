# frozen_string_literal: true

require "object_framework"

class SumNumbers
  def self.call(input)
    { total: input[:numbers].sum }
  end
end

owner = Thread.current.object_id
task = ObjectFramework::Capabilities::IsolatedTask.new(task: SumNumbers)
result = task.call({ numbers: [1, 2, 3] })
puts "Total: #{result[:total]}"
puts "Request thread preserved: #{Thread.current.object_id == owner}"
