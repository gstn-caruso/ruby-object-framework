# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../docs/site"

Spec.test "guide builds produce readable navigation and validate local links and anchors" do
  Dir.mktmpdir("object-framework-guides") do |directory|
    source = File.join(directory, "source")
    output = File.join(directory, "output")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "guides.yml"), <<~YAML)
      - slug: first
        title: First guide
        summary: Build an application.
        section: Start here
      - slug: next
        title: Next guide
        summary: Add persistence.
        section: Start here
    YAML
    File.write(File.join(source, "first.md"), "## A working example\n\nRead [the next step](next.md#why-sessions).\n\n```ruby\nputs '<ok>'\n```\n")
    File.write(File.join(source, "next.md"), "## Why sessions\n\nObjects need an owner.\n")
    GuideSite::Builder.new(source:, destination: output).build
    html = File.read(File.join(output, "first.html"))
    assert html.include?('id="a-working-example"')
    assert html.include?('href="next.html#why-sessions"')
    assert html.include?("&lt;ok&gt;")
    assert html.include?('href="#main"')
    assert html.include?("On this page")
    assert File.file?(File.join(output, "assets/styles.css"))
    File.write(File.join(source, "next.md"), "## Changed heading\n")
    assert_raises(GuideSite::InvalidGuide) { GuideSite::Builder.new(source:, destination: output).build }
  end
end

YAML.safe_load_file(File.expand_path("../examples/guides/manifest.yml", __dir__)).each do |example|
  Spec.test "guide example #{example.fetch('file')} produces its documented result" do
    path = File.expand_path("../examples/guides/#{example.fetch('file')}", __dir__)
    output, error, status = Open3.capture3(example.fetch("env", {}), RbConfig.ruby, "-Ilib", path)
    assert status.success?, "#{example.fetch('file')} failed:\n#{error}"
    assert_equal example.fetch("output"), output
  end
end
