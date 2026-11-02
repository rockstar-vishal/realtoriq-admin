# frozen_string_literal: true

module Marketing
  # The white band under a creative. Sizes come from the shorter side, so a
  # landscape ad does not grow a band that covers a third of the picture.
  # Type never drops under 2%. The band still spans the full width and is
  # joined below the artwork.
  class FooterLayout
    Run = Data.define(:text, :weight, :color)
    Line = Data.define(:text, :size, :weight, :color, :runs, :align, :group, :box)
    Result = Data.define(
      :width, :band_height, :pad, :pad_y, :gap, :stack_gap, :logo_width, :logo_height,
      :drawn_width, :drawn_height, :text_x, :text_block_height, :row1_height, :lines
    )
    NAME_COLOR = "18181B"
    LABEL_COLOR = "3F3F46"
    NUMBER_COLOR = "18181B"
    REG_COLOR = "52525B"
    LINE_FACTOR = { name: 1.2, call: 1.3, registration: 1.35 }.freeze

    def self.call(width:, height:, firm:, project:, numbers:, logo_size:, measurer:, heights: nil, line_measurer: nil)
      new(width:, height:, firm:, project:, numbers:, logo_size:, measurer:, heights:, line_measurer:).call
    end

    def initialize(width:, height:, firm:, project:, numbers:, logo_size:, measurer:, heights:, line_measurer: nil)
      @width = width.to_i
      @height = height.to_i
      @firm = firm
      @project = project
      @numbers = numbers
      @logo_size = logo_size
      @measurer = measurer
      @heights = heights
      @line_measurer = line_measurer
    end

    def call
      @unit = [ @width, (@height * 1.25).round ].min
      @pad = (@unit * 0.06).round
      @pad_y = (@unit * 0.03).round
      @floor = [ (@unit * 0.02).round, 1 ].max
      @gap = (@unit * 0.016).round
      @stack_gap = (@unit * 0.006).round
      @logo_gap = (@unit * 0.03).round
      @name_size = [ (@unit * 0.04).round, @floor ].max
      @name_step = [ (@unit * 0.034).round, @floor ].max
      @call_size = [ (@unit * 0.03).round, @floor ].max
      @reg_size = [ (@unit * 0.024).round, @floor ].max
      @logo_box_h = (@name_size * 1.6).round
      @logo_box_w = (@logo_box_h * 3.5).round

      drawn_w, drawn_h = fitted_logo
      text_x = @pad + (drawn_w.positive? ? drawn_w + @logo_gap : 0)
      name_column = [ @width - text_x - @pad, 1 ].max
      reg_column = [ @width - @pad - @pad, 1 ].max
      lines, row1 = build_lines(name_column, reg_column, drawn_h)
      reg_height = lines.select { |line| line.group == :registration }.sum(&:box)
      section_gap = reg_height.positive? && row1.positive? ? @gap : 0
      text_block = row1 + section_gap + reg_height
      Result.new(
        width: @width, band_height: text_block + (@pad_y * 2), pad: @pad, pad_y: @pad_y, gap: @gap,
        stack_gap: @stack_gap, logo_width: logo? ? @logo_box_w : 0, logo_height: logo? ? @logo_box_h : 0,
        drawn_width: drawn_w, drawn_height: drawn_h, text_x:, text_block_height: text_block,
        row1_height: row1, lines:
      )
    end

    private

    def build_lines(name_column, reg_column, logo_h)
      contacts = FirmContacts.new(@firm)
      runs = call_runs(contacts)
      name = @firm.name.to_s
      stacked = logo? || !beside?(name, runs_width(runs), name_column)
      name_lines = resolve_name(name, name_column, stacked:)
      call = build_call(runs, stacked ? :left : :right) if runs.any?
      regs = registration_lines(contacts, reg_column)
      [ name_lines + [ call ].compact + regs, row1_height(name_lines, call, stacked ? logo_h : 0) ]
    end

    # Beside the call line only when there is no logo and both fit at 4%.
    # Otherwise the call line stacks, and a name that misses 4% steps down to 3.4%
    # before it wraps.
    def resolve_name(name, column, stacked:)
      return [] if name.blank?
      return [ name_line(name, @name_size) ] unless stacked
      return [ name_line(name, @name_size) ] if fits_name?(name, @name_size, column)
      return [ name_line(name, @name_step) ] if fits_name?(name, @name_step, column)

      wrap(name, @name_step, :semibold, NAME_COLOR, column, group: :name)
    end

    def name_line(text, size)
      make_line(text, size, :semibold, NAME_COLOR, group: :name)
    end

    def beside?(name, call_width, column)
      return false if call_width.zero? || name.blank?

      measure(name, @name_size, :semibold) + call_width + @pad <= column
    end

    def fits_name?(text, size, column)
      measure(text, size, :semibold) <= column
    end

    def build_call(runs, align)
      make_line(runs.map(&:text).join, @call_size, :regular, LABEL_COLOR, group: :call, align:, runs:)
    end

    # One line when the column can hold both. Otherwise the two MK2b lines.
    def registration_lines(contacts, column)
      agent = contacts.agent_line(@project)
      project_line = contacts.project_line(@numbers)
      combined = "#{agent}  ·  #{project_line}"
      if measure(combined, @reg_size, :regular) <= column
        [ make_line(combined, @reg_size, :regular, REG_COLOR, group: :registration) ]
      else
        wrap(agent, @reg_size, :regular, REG_COLOR, column, group: :registration) +
          wrap(project_line, @reg_size, :regular, REG_COLOR, column, group: :registration)
      end
    end

    def call_runs(contacts)
      left_raw = contacts.mobile
      right_raw = contacts.whatsapp
      left = Phone.format_for_display(left_raw) if left_raw.present?
      right = Phone.format_for_display(right_raw) if right_raw.present?
      if left && right && left_raw == right_raw
        [ label_run("Call / WhatsApp "), number_run(left) ]
      elsif left && right
        [ label_run("Call "), number_run(left), label_run(" · WhatsApp "), number_run(right) ]
      elsif left
        [ label_run("Call "), number_run(left) ]
      elsif right
        [ label_run("WhatsApp "), number_run(right) ]
      else
        []
      end
    end

    def label_run(text) = Run.new(text:, weight: :regular, color: LABEL_COLOR)

    def number_run(text) = Run.new(text:, weight: :semibold, color: NUMBER_COLOR)

    def row1_height(name_lines, call, logo_h)
      text = if call&.align == :right
        [ name_lines.sum(&:box), call.box ].max
      else
        name_lines.sum(&:box) + (name_lines.any? && call ? @stack_gap : 0) + call&.box.to_i
      end
      [ text, logo_h ].max
    end

    def make_line(text, size, weight, color, group:, align: :left, runs: nil)
      runs ||= [ Run.new(text:, weight:, color:) ]
      Line.new(text:, size:, weight:, color:, runs:, align:, group:, box: box_height(size, group, runs))
    end

    def box_height(size, group, runs)
      box = (size * LINE_FACTOR.fetch(group)).round
      return box unless @heights

      measured = runs.filter_map { |run| @heights.call(run.text, size, run.weight) if run.text.present? }.max.to_i
      [ box, measured ].max
    end

    # Fixed from the 4% name size: 1.6× tall, at most 3.5× that wide. Never upscaled.
    def fitted_logo
      return [ 0, 0 ] unless logo?

      drawn_logo(@logo_box_w, @logo_box_h)
    end

    def logo?
      @logo_size && @logo_size[0].to_i.positive? && @logo_size[1].to_i.positive?
    end

    def drawn_logo(logo_width, logo_height)
      return [ 0, 0 ] unless logo? && logo_width.positive? && logo_height.positive?

      width, height = @logo_size
      scale = [ logo_width.to_f / width, logo_height.to_f / height, 1 ].min
      [ (width * scale).round, (height * scale).round ]
    end

    def runs_width(runs)
      return 0 if runs.empty?
      return @line_measurer.call(runs, @call_size) if @line_measurer

      runs.sum { |run| measure(run.text, @call_size, run.weight) }
    end

    def measure(text, size, weight)
      @measurer.call(text, size, weight)
    end

    def wrap(text, size, weight, color, column, group:)
      words = text.to_s.split(/\s+/)
      return [] if words.empty?

      rows = []
      current = +""
      words.each do |word|
        trial = current.empty? ? word : "#{current} #{word}"
        if current.empty? || measure(trial, size, weight) <= column
          current = trial
        else
          rows << current
          current = word
        end
      end
      rows << current if current.present?
      rows.map { |row| make_line(row, size, weight, color, group:) }
    end
  end
end
