# frozen_string_literal: true

require "object_framework"

class Greet
  def initialize(greeting:)
    @greeting = greeting
  end

  def call(name:)
    { message: "#{@greeting}, #{name}" }
  end
end

app = ObjectFramework::Application.new
app.factory(:greeting) { "Hello" }
app.operation(:greet, use_case: Greet, policy: :none, dependencies: [:greeting])
app.start
begin
  result = app.invoke(:greet, name: "Ada")
  puts result[:message]
  puts "Result is frozen: #{result.frozen?}"
ensure
  app.stop
end
