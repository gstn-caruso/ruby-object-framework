# frozen_string_literal: true

class Greet
  def initialize(greeting:)
    @greeting = greeting
  end

  def call(name:)
    "#{@greeting}, #{name}"
  end
end

puts Greet.new(greeting: "Hello").call(name: "Ada")
