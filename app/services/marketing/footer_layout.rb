# frozen_string_literal: true

module Marketing
  # The white band under a creative. Sizes are shares of the width. The RERA
  # line wraps onto another line and the band grows; type never drops under 2%.
  class FooterLayout
    Line = Data.define(:text, :size, :weight, :color)
    Result = Data.define(
      :width, :band_height, :pad, :logo_width, :logo_height, :drawn_width, :drawn_height, :text_x, :lines
    )
    NAME_COLOR = "18181B"
    BODY_COLOR = "3F3F46"

    def self.call(width:, firm:, project:, numbers:, logo_size:, measurer:)
      new(width:, firm:, project:, numbers:, logo_size:, measurer:).call
    end

    def initialize(width:, firm:, project:, numbers:, logo_size:, measurer:)
      @width = width.to_i
      @firm = firm
      @project = project
      @numbers = numbers
      @logo_size = logo_size
      @measurer = measurer
    end

    def call
      pad = [ (@width * 0.04).round, 4 ].max
      base = [ (@width * 0.14).round, 120 ].max
      logo_height = logo? ? (base * 0.60).round : 0
      logo_width = logo_height * 2
      drawn_w, drawn_h = drawn_logo(logo_width, logo_height)
      text_x = pad + (drawn_w.positive? ? drawn_w + pad : 0)
      column = [ @width - text_x - pad, 1 ].max
      name_size = [ (@width * 0.032).round, 1 ].max
      body_size = [ (@width * 0.024).round, 1 ].max
      lines = wrapped_lines(name_size, body_size, column)
      content = lines.sum { |line| (line.size * 1.35).round } + (lines.size * 4)
      band = [ base, content + (pad / 2) ].max
      Result.new(
        width: @width, band_height: band, pad:, logo_width:, logo_height:,
        drawn_width: drawn_w, drawn_height: drawn_h, text_x:, lines:
      )
    end

    private

    def wrapped_lines(name_size, body_size, column)
      contacts = FirmContacts.new(@firm)
      lines = wrap(@firm.name.to_s, name_size, :semibold, NAME_COLOR, column)
      phone = contacts.call_line
      lines.concat(wrap(phone, body_size, :regular, BODY_COLOR, column)) if phone.present?
      lines.concat(wrap(contacts.agent_line(@project), body_size, :regular, BODY_COLOR, column))
      lines.concat(wrap(contacts.project_line(@numbers), body_size, :regular, BODY_COLOR, column))
      lines
    end

    def logo?
      @logo_size && @logo_size[0].to_i.positive? && @logo_size[1].to_i.positive?
    end

    # Height stays 60% of the base band. Width may be twice that, so a wordmark
    # is readable. The logo is never upscaled, and the text starts one pad
    # after the width actually drawn.
    def drawn_logo(logo_width, logo_height)
      return [ 0, 0 ] unless logo? && logo_width.positive? && logo_height.positive?

      width, height = @logo_size
      scale = [ logo_width.to_f / width, logo_height.to_f / height, 1 ].min
      [ (width * scale).round, (height * scale).round ]
    end

    def wrap(text, size, weight, color, column)
      words = text.to_s.split(/\s+/)
      return [] if words.empty?

      rows = []
      current = +""
      words.each do |word|
        trial = current.empty? ? word : "#{current} #{word}"
        if current.empty? || @measurer.call(trial, size, weight) <= column
          current = trial
        else
          rows << current
          current = word
        end
      end
      rows << current if current.present?
      rows.map { |row| Line.new(text: row, size:, weight:, color:) }
    end
  end
end
