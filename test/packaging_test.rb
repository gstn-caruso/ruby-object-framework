# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

Spec.test "the gem installs outside the checkout with every adapter and no mandatory SQLite dependency" do
  root = File.expand_path("..", __dir__)
  Dir.mktmpdir("object-framework-gem-") do |directory|
    archive = File.join(directory, "framework.gem")
    output, status = Open3.capture2e(RbConfig.ruby, "-S", "gem", "build",
      "ruby-object-framework.gemspec", "--strict", "--output", archive, chdir: root)
    assert status.success?, output

    package = Gem::Package.new(archive)
    assert_equal "ruby-object-framework", package.spec.name
    assert_equal [], package.spec.runtime_dependencies
    expected = Dir.chdir(root) { Dir["lib/**/*.rb"].sort }
    assert_equal expected, package.spec.files.grep(%r{\Alib/}).sort
    assert package.spec.files.include?("examples/orders/server.rb")
    assert package.spec.files.include?("THIRD_PARTY_NOTICES.md")
    assert package.spec.files.include?("API.md")
    assert package.spec.files.none? { |path| path.match?(%r{\A(?:test|node_modules|\.git|\.venv|pkg)/}) }

    gem_home = File.join(directory, "gems")
    environment = { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "RUBYOPT" => nil }
    output, status = Open3.capture2e(environment, RbConfig.ruby, "-S", "gem", "install",
      archive, "--local", "--no-document", chdir: directory)
    assert status.success?, output

    smoke = <<~RUBY
      require "object_framework"
      abort "SQLite loaded eagerly" if $LOADED_FEATURES.any? { |path| path.include?("sqlite3") }
      app = ObjectFramework::Application.new
      app.operation(:hello, use_case: Class.new { def call; "Hello from the gem"; end }, policy: :none)
      app.start
      abort "Invocation failed" unless app.invoke(:hello) == "Hello from the gem"
      app.stop
      abort "Version mismatch" unless ObjectFramework::VERSION == #{package.spec.version.to_s.inspect}
      abort "SQLite missing" unless File.file?(File.join(Gem.loaded_specs.fetch("ruby-object-framework").full_gem_path,
        "lib/object_framework/sqlite/storage.rb"))
      puts ObjectFramework::VERSION
    RUBY
    output, status = Open3.capture2e(environment, RbConfig.ruby, "-e", smoke, chdir: directory)
    assert status.success?, output
    assert_equal package.spec.version.to_s, output.strip
  end
end

Spec.test "release preparation builds the semantic version and rejects invalid versions without changing source" do
  root = File.expand_path("..", __dir__)
  Dir.mktmpdir("object-framework-release-") do |directory|
    FileUtils.cp_r(File.join(root, "lib"), directory)
    %w[ruby-object-framework.gemspec Gemfile Gemfile.lock].each do |path|
      FileUtils.cp(File.join(root, path), directory)
    end
    FileUtils.mkdir_p(File.join(directory, "tools"))
    FileUtils.cp(File.join(root, "tools/prepare_release.rb"), File.join(directory, "tools"))
    script = File.join(directory, "tools/prepare_release.rb")
    version_file = File.join(directory, "lib/object_framework/version.rb")
    original = File.read(version_file)

    ["1.2", "01.2.3", "1.2.3; echo bad", "1.2.3.pre"].each do |version|
      output, status = Open3.capture2e(RbConfig.ruby, script, version, chdir: root)
      assert !status.success?, output
      assert_equal original, File.read(version_file)
      assert !Dir.exist?(File.join(directory, "pkg"))
    end

    empty_gems = File.join(directory, "empty-gems")
    output, status = Open3.capture2e({ "GEM_HOME" => empty_gems, "GEM_PATH" => empty_gems, "RUBYOPT" => nil },
      RbConfig.ruby, script, "2.3.4", chdir: root)
    assert status.success?, output
    package = Gem::Package.new(File.join(directory, "pkg/ruby-object-framework-2.3.4.gem"))
    assert_equal "2.3.4", package.spec.version.to_s
    assert File.read(version_file).include?('VERSION = "2.3.4"')
    assert File.read(File.join(directory, "Gemfile.lock")).include?("ruby-object-framework (2.3.4)")
  end
end
