# frozen_string_literal: true

require "rdoc/rdoc"
require "fileutils"
require_relative "../lib/object_framework/version"

module GuideSite
  class APIReference
    def build(destination:)
      FileUtils.rm_rf(destination)
      Dir.chdir(ROOT) do
        RDoc::RDoc.new.document([
          "--op", destination,
          "--title", "ObjectFramework #{ObjectFramework::VERSION} API",
          "--main", "API.md",
          "--visibility", "public",
          "--template-stylesheets", "docs/assets/api.css",
          "--quiet",
          "lib", "API.md"
        ])
      end
    end
  end
end
