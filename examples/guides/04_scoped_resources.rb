# frozen_string_literal: true

require "object_framework"

class Resource
  def initialize(events:)
    @events = events
    @events << "opened"
  end

  def close
    @events << "closed"
  end
end

class CompareResources
  def initialize(first:, second:)
    @first, @second = first, second
  end

  def call
    @first.equal?(@second)
  end
end

events = []
app = ObjectFramework::Application.new
app.factory(:resource, close: true) { Resource.new(events:) }
app.factory(:first, dependencies: [:resource]) { |resource:| resource }
app.factory(:second, dependencies: [:resource]) { |resource:| resource }
app.operation(:compare, use_case: CompareResources, policy: :none, dependencies: [:first, :second])
app.start
begin
  puts "Same resource: #{app.invoke(:compare)}"
  puts events.join(", ")
ensure
  app.stop
end
