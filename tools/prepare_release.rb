# frozen_string_literal: true

require "fileutils"
require "rbconfig"

version = ARGV.first
unless ARGV.size == 1 && version.match?(/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/)
  abort "Usage: ruby tools/prepare_release.rb MAJOR.MINOR.PATCH"
end

root = File.expand_path("..", __dir__)
File.write(File.join(root, "lib/object_framework/version.rb"), <<~RUBY)
  # frozen_string_literal: true

  module ObjectFramework
    VERSION = #{version.inspect}
  end
RUBY

system(RbConfig.ruby, "-S", "bundle", "lock", "--local", chdir: root, exception: true)
FileUtils.mkdir_p(File.join(root, "pkg"))
system(RbConfig.ruby, "-S", "gem", "build", "ruby-object-framework.gemspec", "--strict",
  "--output", "pkg/ruby-object-framework-#{version}.gem", chdir: root, exception: true)
