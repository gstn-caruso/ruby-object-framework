# frozen_string_literal: true

abort "Ruby 4.0.8 is required" unless RUBY_VERSION == "4.0.8"
require_relative "../docs/site"

count = GuideSite::Builder.new.build
puts "Built #{count} guides; local links and anchors verified. Output: _site/"
