# frozen_string_literal: true

module Legal
  # HTML for the legal pages. Text is escaped before any tag is added.
  class HtmlRenderer
    def initialize(document)
      @document = document
    end

    def render
      blocks = Markdown.parse(document.text)
      parts = [ table_of_contents(blocks) ]
      parts.concat(render_blocks(blocks))
      parts.compact.reduce(ActiveSupport::SafeBuffer.new, :<<)
    end

    private

    attr_reader :document

    def table_of_contents(blocks)
      headings = blocks.select { |block| block.type == :h2 }
      return if headings.empty?

      items = headings.map { |block| %(<li><a href="##{slug(block.text)}">#{inline(block.text)}</a></li>) }
      %(<nav class="toc"><ol>#{items.join}</ol></nav>).html_safe
    end

    def render_blocks(blocks)
      parts = []
      index = 0
      while index < blocks.length
        if blocks[index].type == :li
          html, index = render_list(blocks, index, blocks[index].depth)
          parts << html
        else
          parts << render_block(blocks[index])
          index += 1
        end
      end
      parts
    end

    # Consecutive items become one list. A deeper item is a list inside the
    # previous item, not a second list with a margin.
    def render_list(blocks, index, depth)
      items = []
      while index < blocks.length && blocks[index].type == :li && blocks[index].depth == depth
        text = inline(blocks[index].text)
        index += 1
        nested = "".html_safe
        if index < blocks.length && blocks[index].type == :li && blocks[index].depth > depth
          nested, index = render_list(blocks, index, blocks[index].depth)
        end
        items << %(<li>#{text}#{nested}</li>)
      end
      [ %(<ul>#{items.join}</ul>).html_safe, index ]
    end

    def render_block(block)
      case block.type
      when :h1 then tag("h1", block.text)
      when :h2 then %(<h2 id="#{slug(block.text)}">#{inline(block.text)}</h2>).html_safe
      when :h3 then tag("h3", block.text)
      else
        tag("p", block.text)
      end
    end

    def tag(name, text)
      %(<#{name}>#{inline(text)}</#{name}>).html_safe
    end

    def inline(text)
      escaped = ERB::Util.html_escape(text.to_s)
      autolink(escaped).gsub(/\*\*(.+?)\*\*/, "<strong>\\1</strong>").html_safe
    end

    def autolink(escaped)
      escaped
        .gsub(%r{https://[^\s<]+}) { |url| %(<a href="#{url}">#{url}</a>) }
        .gsub(/\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i) { |email| %(<a href="mailto:#{email}">#{email}</a>) }
    end

    def slug(text)
      text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    end
  end
end
