# frozen_string_literal: true

module Form6
  # The Form 6 .docx. WordprocessingML, A4 portrait, one-inch margins, Segoe UI.
  # The letterhead replaces the official "[On the letterhead…]" line. Every
  # value is escaped: stdlib ERB does not escape `<%= %>`.
  class Document
    CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    BLANK_ROWS = 3
    TABLE_A_HEADERS = [ "S. No.", "Name of the Project", "MahaRERA Project Registration Number" ].freeze
    TABLE_B_HEADERS = [
      "S. No.",
      "Name of the Project",
      "MahaRERA Project Registration Number",
      "Whether Plot/ shop/apartment/ others",
      "Residential or Commercial or others",
      "Unit Number in the project",
      "Date of Transaction",
      "Amount of Agent Fees levied for this transaction"
    ].freeze
    TABLE_C_HEADERS = [
      "",
      "Name",
      "Date of appointment",
      "Mobile Number",
      "Email Address",
      "Contact Address"
    ].freeze
    TABLE_A_WIDTHS = [ 900, 4500, 3626 ].freeze
    # 9pt body. Widths sum to 9026. noWrap on the MahaRERA number, category,
    # unit, date and fee so a word is not broken across lines.
    TABLE_B_WIDTHS = [ 500, 1450, 1400, 1100, 1250, 926, 1250, 1150 ].freeze
    TABLE_A_NOWRAP = [ 2 ].freeze
    TABLE_B_NOWRAP = [ 2, 4, 5, 6, 7 ].freeze
    TABLE_C_WIDTHS = [ 1500, 1400, 1500, 1400, 1700, 1526 ].freeze

    def self.filename_for(firm:, period:)
      firm_part = firm.name.to_s.strip.gsub(/[^A-Za-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      firm_part = "Firm" if firm_part.blank?
      "Form6_#{firm_part}_#{period.filename_part}.docx"
    end

    def initialize(firm:, period:, today: Date.current)
      @firm = firm
      @period = period
      @today = today
      @report = Report.new(firm:, period:)
      @settings = Settings.read(firm)
    end

    def filename
      self.class.filename_for(firm:, period:)
    end

    def to_docx
      require "zip"

      buffer = Zip::OutputStream.write_buffer do |zip|
        parts.each do |path, body|
          zip.put_next_entry(path)
          zip.write(body.to_s.encode(Encoding::UTF_8).b)
        end
      end
      buffer.string
    end

    private

    attr_reader :firm, :period, :today, :report, :settings

    def parts
      {
        "[Content_Types].xml" => Package::CONTENT_TYPES,
        "_rels/.rels" => Package::ROOT_RELS,
        "word/document.xml" => document_xml,
        "word/_rels/document.xml.rels" => Package::DOCUMENT_RELS,
        "word/styles.xml" => Package::STYLES,
        "word/settings.xml" => Package::SETTINGS
      }
    end

    def document_xml
      ERB.new(Rails.root.join("app/services/form6/templates/document.xml.erb").read, trim_mode: "-").result(binding)
    end

    def letterhead_lines
      address = [
        firm.address_line1, firm.address_line2, firm.locality&.name, firm.city&.name, firm.pincode
      ].compact_blank.join(", ")
      rera = firm.rera_number.present? ? "MahaRERA #{firm.rera_number}" : nil
      [ firm.name, address.presence, rera ].compact
    end

    def agent_name
      Settings.agent_name(firm).to_s
    end

    def competency_certificate_no
      settings["competency_certificate_no"].to_s
    end

    def signatory_name
      settings["signatory_name"].to_s
    end

    def signatory_designation
      settings["signatory_designation"].to_s
    end

    def table_a_rows
      rows = report.designated_projects.each_with_index.map do |project, index|
        [ (index + 1).to_s, project.name.to_s, project.rera_number.to_s ]
      end
      pad(rows, TABLE_A_HEADERS.size)
    end

    def table_b_rows
      rows = report.table_b_rows.each_with_index.map do |booking, index|
        typology = booking.typology
        [
          (index + 1).to_s,
          booking.project&.name.to_s,
          booking.project&.rera_number.to_s,
          Classification.unit_type(typology).to_s,
          Classification.category_label(typology).to_s,
          booking.unit_no.to_s,
          dmy(booking.booked_on),
          Money.group(booking.commission_amount + booking.kicker.to_i)
        ]
      end
      pad(rows, TABLE_B_HEADERS.size)
    end

    def table_c_rows
      [
        person_row("Principal Officer", "principal_officer"),
        person_row("Designated Director", "designated_director")
      ]
    end

    def person_row(label, key)
      person = turnover? && settings[key].is_a?(Hash) ? settings[key] : {}
      [
        label,
        person["name"].to_s,
        dmy(person["appointed_on"]),
        person["mobile"].present? ? Phone.format_for_display(person["mobile"]) : "",
        person["email"].to_s,
        person["address"].to_s
      ]
    end

    def turnover?
      settings["turnover_20l_or_more"] == true
    end

    def pad(rows, width)
      return rows if rows.any?

      Array.new(BLANK_ROWS) { Array.new(width, "") }
    end

    def dmy(date)
      return "" if date.blank?

      date.to_date.strftime("%d/%m/%Y")
    end

    # runs are [text, bold, underline]. A single string is one regular run
    # unless bold or underline is set. Body text is 11pt (sz 22).
    def paragraph(text = nil, align: nil, bold: false, underline: false, size: 22,
      before: 0, after: 60, indent: nil, runs: nil, keep_next: false, keep_lines: false)
      pieces = runs || [ [ text.to_s, bold, underline ] ]
      alignment = align ? %(<w:jc w:val="#{align}"/>) : ""
      left = indent ? %(<w:ind w:left="#{indent.to_i}"/>) : ""
      follow = keep_next ? "<w:keepNext/>" : ""
      together = keep_lines ? "<w:keepLines/>" : ""
      <<~XML
        <w:p>
          <w:pPr>
            #{follow}
            #{together}
            <w:spacing w:before="#{before.to_i}" w:after="#{after.to_i}" w:line="240" w:lineRule="auto"/>
            #{alignment}
            #{left}
          </w:pPr>
          #{pieces.map { |piece, weight, line| text_run(piece, bold: weight, underline: line, size:) }.join}
        </w:p>
      XML
    end

    def text_run(text, bold:, underline:, size:)
      weight = bold ? "<w:b/><w:bCs/>" : ""
      line = underline ? '<w:u w:val="single"/>' : ""
      <<~XML
        <w:r>
          <w:rPr>
            <w:rFonts w:ascii="Segoe UI" w:hAnsi="Segoe UI" w:cs="Segoe UI"/>
            <w:sz w:val="#{size.to_i}"/>
            <w:szCs w:val="#{size.to_i}"/>
            #{weight}
            #{line}
          </w:rPr>
          <w:t xml:space="preserve">#{x(text)}</w:t>
        </w:r>
      XML
    end

    def labeled(label, value, align: nil, indent: nil, after: 40, keep_next: false, keep_lines: false)
      paragraph(
        align:, indent:, after:, keep_next:, keep_lines:,
        runs: [ [ "#{label} ", true, false ], [ value.to_s, false, false ] ]
      )
    end

    def grid(headers, rows, widths, nowrap_columns: [])
      body = +%(<w:tbl><w:tblPr><w:tblW w:w="9026" w:type="dxa"/><w:tblLayout w:type="fixed"/>#{borders}</w:tblPr>)
      body << "<w:tblGrid>"
      widths.each { |width| body << %(<w:gridCol w:w="#{width}"/>) }
      body << "</w:tblGrid>"
      body << table_row(headers, widths, header: true, nowrap_columns:)
      rows.each { |row| body << table_row(row, widths, header: false, nowrap_columns:) }
      body << "</w:tbl>"
      body
    end

    def table_row(values, widths, header:, nowrap_columns:)
      cells = values.each_with_index.map do |value, index|
        table_cell(value, widths[index], header:, nowrap: nowrap_columns.include?(index))
      end
      mark = header ? "<w:tblHeader/>" : ""
      "<w:tr><w:trPr>#{mark}<w:cantSplit/></w:trPr>#{cells.join}</w:tr>"
    end

    def table_cell(value, width, header:, nowrap:)
      weight = header ? "<w:b/><w:bCs/>" : ""
      wrap = nowrap && !header ? "<w:noWrap/>" : ""
      <<~XML
        <w:tc>
          <w:tcPr><w:tcW w:w="#{width}" w:type="dxa"/>#{wrap}</w:tcPr>
          <w:p>
            <w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr>
            <w:r>
              <w:rPr>
                <w:rFonts w:ascii="Segoe UI" w:hAnsi="Segoe UI" w:cs="Segoe UI"/>
                <w:sz w:val="18"/>
                <w:szCs w:val="18"/>
                #{weight}
              </w:rPr>
              <w:t xml:space="preserve">#{x(value)}</w:t>
            </w:r>
          </w:p>
        </w:tc>
      XML
    end

    def borders
      edge = '<w:%<side>s w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
      sides = %w[top left bottom right insideH insideV].map { |side| format(edge, side:) }
      "<w:tblBorders>#{sides.join}</w:tblBorders>"
    end

    def x(value)
      text = value.to_s.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, "")
      ERB::Util.html_escape(text)
    end
  end
end
