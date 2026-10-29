# frozen_string_literal: true

module Marketing
  # Inter for Latin, Noto Sans Devanagari for Devanagari. The four files are
  # registered once; later renders name them in markup and do not shell out.
  module Fonts
    INTER_FAMILY = "Inter"
    DEVANAGARI_FAMILY = "Noto Sans Devanagari"
    WEIGHTS = { regular: 400, semibold: 600 }.freeze
    FC_WEIGHTS = { regular: 80, semibold: 180 }.freeze
    STYLES = { regular: "Regular", semibold: "SemiBold" }.freeze
    INTER = Rails.root.join("app/assets/fonts/inter")
    DEVANAGARI = Rails.root.join("vendor/fonts/noto-sans-devanagari")
    DEVANAGARI_RANGES = [ 0x0900..0x097F, 0xA8E0..0xA8FF, 0x1CD0..0x1CFF ].freeze

    def self.ttf(weight)
      name = weight == :semibold ? "inter-latin-600-normal.ttf" : "inter-latin-400-normal.ttf"
      INTER.join(name).to_s
    end

    def self.devanagari_ttf(weight)
      name = weight == :semibold ? "NotoSansDevanagari-SemiBold.ttf" : "NotoSansDevanagari-Regular.ttf"
      DEVANAGARI.join(name).to_s
    end

    def self.files
      [ ttf(:regular), ttf(:semibold), devanagari_ttf(:regular), devanagari_ttf(:semibold) ]
    end

    def self.description(weight, size)
      face = weight == :semibold ? "Inter Semi-Bold" : "Inter"
      "#{face} #{size}"
    end

    def self.markup(text, weight)
      weight_value = WEIGHTS.fetch(weight)
      runs(text).map { |run| span(run[:text], run[:script], weight_value) }.join
    end

    def self.render(text, size:, weight:)
      register!
      require "vips"
      Vips::Image.text(markup(text, weight), font: description(weight, size), dpi: 72)
    end

    # fontfile adds a face for the rest of the process. Warm up all four so a
    # later render can name them without passing fontfile again.
    def self.register!
      return if defined?(@registered) && @registered

      require "vips"
      [ [ ttf(:regular), "A" ], [ ttf(:semibold), "A" ],
        [ devanagari_ttf(:regular), "अ" ], [ devanagari_ttf(:semibold), "अ" ] ].each do |path, sample|
        Vips::Image.text(sample, fontfile: path, dpi: 72)
      end
      @registered = true
    end

    # Specs compare these with fc-scan. Rendering never calls it.
    def self.fc_scan(path)
      require "open3"
      output, status = Open3.capture2(
        "fc-scan", "--format", "%{family[0]}\n%{style[0]}\n%{weight}\n", path.to_s
      )
      return unless status.success?

      family, style, weight = output.lines.map(&:strip)
      return if family.blank? || style.blank? || weight.blank?

      { family:, style:, weight: weight.to_i }
    end

    def self.escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def self.span(text, script, weight_value)
      family = script == :devanagari ? DEVANAGARI_FAMILY : INTER_FAMILY
      %(<span font_family="#{family}" font_weight="#{weight_value}">#{escape(text)}</span>)
    end

    def self.runs(text)
      chars = text.to_s.each_char.to_a
      return [] if chars.empty?

      deva = chars.map { |char| devanagari?(char) }
      glue = chars.map { |char| glue?(char) }
      absorbed = absorb_glue(deva, glue)
      group(chars, absorbed)
    end

    def self.absorb_glue(deva, glue)
      absorbed = deva.dup
      glue.each_index do |index|
        next unless glue[index] && !deva[index]

        left = (index - 1).downto(0).find { |cursor| !glue[cursor] }
        right = (index + 1).upto(glue.length - 1).find { |cursor| !glue[cursor] }
        absorbed[index] = true if left && right && deva[left] && deva[right]
      end
      absorbed
    end

    def self.group(chars, devanagari_run)
      runs = []
      chars.each_with_index do |char, index|
        script = devanagari_run[index] ? :devanagari : :latin
        if runs.last && runs.last[:script] == script
          runs.last[:text] << char
        else
          runs << { script:, text: +char }
        end
      end
      runs
    end

    def self.devanagari?(char)
      code = char.ord
      DEVANAGARI_RANGES.any? { |range| range.cover?(code) }
    end

    def self.glue?(char)
      char.match?(/[[:space:]]/) || char.match?(/[[:digit:]]/) || char.match?(/[[:punct:]]/)
    end
    private_class_method :escape, :span, :runs, :absorb_glue, :group, :devanagari?, :glue?
  end
end
