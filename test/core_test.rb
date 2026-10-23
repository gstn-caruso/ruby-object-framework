# frozen_string_literal: true

require "object_framework"

Spec.test "a use case is an ordinary Ruby object with constructor collaborators" do
  use_case = Class.new do
    def initialize(greeting:)
      @greeting = greeting
    end

    def call(name:)
      "#{@greeting}, #{name}"
    end
  end
  app = ObjectFramework::Application.new
  app.factory(:greeting) { "Hello" }
  app.operation(:greet, use_case:, policy: :none, dependencies: [:greeting])
  app.start
  assert_equal "Hello, Ada", app.invoke(:greet, name: "Ada")
ensure
  app&.stop
end
