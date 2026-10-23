# frozen_string_literal: true

abort "Ruby 4.0.8 is required (running #{RUBY_VERSION})" unless RUBY_VERSION == "4.0.8"

require_relative "support/spec"
files = ARGV.empty? ? Dir[File.join(__dir__, "**/*_test.rb")].sort : ARGV
files.each { |file| require File.expand_path(file) }
exit Spec.run
