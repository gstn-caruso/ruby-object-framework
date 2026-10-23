# frozen_string_literal: true

require "object_framework"

class RequestCounter
  attr_reader :operation_id

  def initialize(context:)
    @operation_id, @count = context.operation_id, 0
  end

  def next_value
    @count += 1
  end

  def close
    puts "Counter closed"
  end
end

class CountTwice
  def initialize(first:, second:)
    @first, @second = first, second
  end

  def call
    { counts: [@first.next_value, @second.next_value], operation_id: @first.operation_id }
  end
end

app = ObjectFramework::Application.new
app.bean(:counter, RequestCounter, close: true)
app.bean(:first) { |counter:| counter }
app.bean(:second) { |counter:| counter }
app.operation(:count, use_case: CountTwice, policy: :none)
app.start
begin
  results = 2.times.map do |index|
    result = app.invoke(:count)
    puts "Request #{index + 1}: #{result[:counts].join(', ')}"
    result
  end
  puts "Independent contexts: #{results[0][:operation_id] != results[1][:operation_id]}"
ensure
  app.stop
end
