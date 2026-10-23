# frozen_string_literal: true

require "yaml"
require "erb"
require "cgi"
require "fileutils"
require "uri"
require "rdoc"
require "rdoc/markdown"
require "rdoc/markup/to_html"

module GuideSite
  ROOT = File.expand_path("..", __dir__)
  class InvalidGuide < StandardError; end
  Guide = Data.define(:slug, :title, :summary, :section)

  class Renderer < RDoc::Markup::ToHtml
    attr_reader :headings

    def initialize
      super(RDoc::Options.new)
      @headings = []
    end

    def accept_heading(heading)
      raise InvalidGuide, "Guide sources start at heading level 2" if heading.level == 1
      text = heading.text.gsub(/<[^>]+>/, "").gsub(/[`*_]/, "")
      slug = CGI.unescapeHTML(text).downcase.gsub(/[^a-z0-9]+/, "-").sub(/\A-/, "").sub(/-\z/, "")
      raise InvalidGuide, "Empty or duplicate guide heading: #{text}" if slug.empty? || headings.any? { |item| item[:id] == slug }
      @headings << { id: slug, text:, level: heading.level }
      @res << "\n<h#{heading.level} id=\"#{slug}\"><a href=\"##{slug}\">#{to_html(heading.text)}</a></h#{heading.level}>\n"
    end
  end

  class Builder
    attr_reader :guides

    def initialize(source: File.join(__dir__, "guides"), destination: File.join(ROOT, "_site"))
      @source, @destination = File.expand_path(source), File.expand_path(destination)
      @repository = "https://github.com/#{ENV.fetch('GUIDES_REPOSITORY', 'gstn-caruso/ruby-object-framework')}"
      @guides = YAML.safe_load_file(File.join(@source, "guides.yml")).map do |entry|
        raise InvalidGuide, "Invalid guide slug" unless /\A[a-z][a-z0-9_-]*\z/.match?(entry.fetch("slug"))
        Guide.new(**entry.transform_keys(&:to_sym))
      end
      raise InvalidGuide, "Guide slugs must be unique" unless @guides.map(&:slug).uniq.size == @guides.size
    end

    def build
      FileUtils.mkdir_p(@destination)
      FileUtils.cp_r(File.join(__dir__, "assets"), @destination)
      template = ERB.new(File.read(File.join(__dir__, "layout.html.erb")), trim_mode: "-")
      @guides.each_with_index do |guide, index|
        source = File.read(File.join(@source, "#{guide.slug}.md"))
        source = include_examples(source)
        source = source.gsub(/(\]\()([a-z][a-z0-9_-]*)\.md(?=[#)])/, '\1\2.html')
        renderer = Renderer.new
        body = RDoc::Markdown.parse(source).accept(renderer)
        headings = renderer.headings.select { |heading| heading[:level] <= 3 }
        previous, following = index.positive? ? @guides[index - 1] : nil, @guides[index + 1]
        File.write(File.join(@destination, "#{guide.slug}.html"), template.result(binding))
      end
      guide = previous = following = nil
      headings = []
      body = ERB.new(File.read(File.join(__dir__, "index.html.erb")), trim_mode: "-").result(binding)
      File.write(File.join(@destination, "index.html"), template.result(binding))
      File.write(File.join(@destination, ".nojekyll"), "")
      validate!
      @guides.size
    end

    def h(text); CGI.escapeHTML(text.to_s); end

    def validate!
      files = Dir[File.join(@destination, "*.html")]
      anchors = files.to_h do |file|
        ids = File.read(file).scan(/\bid="([^"]+)"/).flatten
        raise InvalidGuide, "Duplicate anchors in #{file}" unless ids.uniq.size == ids.size
        [file, ids]
      end
      files.each do |file|
        File.read(file).scan(/(?:href|src)="([^"]+)"/).flatten.each do |link|
          uri = URI.parse(CGI.unescapeHTML(link))
          next if uri.scheme || uri.host
          target = uri.path.empty? ? file : File.expand_path(uri.path, File.dirname(file))
          unless target.start_with?(@destination + "/") && File.file?(target)
            raise InvalidGuide, "Broken local link #{link} in #{File.basename(file)}"
          end
          if uri.fragment && anchors.key?(target) && !anchors.fetch(target).include?(uri.fragment)
            raise InvalidGuide, "Missing anchor #{link} in #{File.basename(file)}"
          end
        end
      end
      true
    end

    private

    def include_examples(source)
      source.gsub(/<!-- example: ([a-zA-Z0-9_\/.\-]+\.rb) -->/) do
        relative = Regexp.last_match(1)
        path = File.expand_path(relative, ROOT)
        raise InvalidGuide, "Example must belong to the repository" unless path.start_with?(ROOT + "/examples/") && File.file?(path)
        "```ruby\n#{File.read(path).delete_prefix("# frozen_string_literal: true\n\n")}\n```\n\n[Full example source](#{@repository}/blob/main/#{relative})."
      end
    end
  end
end
