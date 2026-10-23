# frozen_string_literal: true

require "object_framework"

first = ObjectFramework::Capabilities::Definitions.new
second = ObjectFramework::Capabilities::Definitions.new
first.evaluate("class Name; def self.call; 'first application'; end; end")
second.evaluate("class Name; def self.call; 'second application'; end; end")
puts first.constant(:Name).call
puts second.constant(:Name).call
puts "Definitions leaked: #{Object.const_defined?(:Name)}"
