# frozen_string_literal: true

module Legal
  # The small subset the legal texts actually use. Anything else stays plain text.
  class Markdown
    Block = Struct.new(:type, :text, :depth, keyword_init: true)

    def self.parse(source)
      blocks = []
      paragraph = []
      flush = lambda do
        next if paragraph.empty?

        blocks << Block.new(type: :p, text: paragraph.join(" "), depth: 0)
        paragraph.clear
      end

      source.to_s.each_line do |line|
        stripped = line.rstrip
        if stripped.blank?
          flush.call
          next
        end

        if (heading = stripped.match(/\A(\#{1,3}) (.+)\z/))
          flush.call
          blocks << Block.new(type: :"h#{heading[1].length}", text: heading[2].strip, depth: 0)
        elsif (bullet = stripped.match(/\A( *)- (.+)\z/))
          flush.call
          blocks << Block.new(type: :li, text: bullet[2].strip, depth: bullet[1].length / 2)
        else
          paragraph << stripped.strip
        end
      end

      flush.call
      blocks
    end
  end
end
