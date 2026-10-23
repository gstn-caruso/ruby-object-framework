# frozen_string_literal: true

require_relative "lib/object_framework/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-object-framework"
  spec.version = ObjectFramework::VERSION
  spec.authors = ["Gastón Caruso"]
  spec.email = ["gstn.caruso@gmail.com"]
  spec.summary = "A modular Ruby framework built from collaborating objects"
  spec.description = "Explicit application composition, scoped execution, Data Mapper persistence, " \
    "HTTP and native gRPC, with an optional SQLite adapter."
  spec.homepage = "https://github.com/gstn-caruso/ruby-object-framework"
  spec.license = "Nonstandard"
  spec.required_ruby_version = "~> 4.0.8"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "https://gstn-caruso.github.io/ruby-object-framework/",
    "changelog_uri" => "#{spec.homepage}/releases",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "examples/**/*", "README.md", "API.md", "THIRD_PARTY_NOTICES.md"].select { |path| File.file?(path) }.sort
  end
  spec.extra_rdoc_files = spec.files.grep(/\A(?:README|API)\.md\z/)
  spec.rdoc_options = ["--main", "API.md", "--visibility", "public"]
  spec.require_paths = ["lib"]
end
