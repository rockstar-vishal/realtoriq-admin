# frozen_string_literal: true

module Legal
  # Page 1 is the record of acceptance. The terms and the privacy policy follow,
  # rendered from the same markdown the site serves.
  class AcceptancePdf
    FONT_DIR = Rails.root.join("vendor/fonts/noto-sans")

    def initialize(acceptance, application)
      @acceptance = acceptance
      @application = application
    end

    def render
      pdf = Prawn::Document.new(page_size: "A4", margin: 48, info: metadata)
      register_fonts(pdf)
      record_page(pdf)
      pdf.start_new_page
      document_page(pdf, "Terms & Conditions", terms.text)
      pdf.start_new_page
      document_page(pdf, "Privacy Policy", privacy.text)
      generated = stamp(Time.current)
      pdf.number_pages(
        "Ref #{application.reference} · Generated #{generated} · Page <page> of <total>",
        at: [ 0, 16 ], width: pdf.bounds.width, align: :center, size: 8
      )
      pdf.render
    end

    private

    attr_reader :acceptance, :application

    def metadata
      {
        Title: "RealtorIQ Terms #{application.reference}",
        Author: "KGen Intelligence Private Limited",
        CreationDate: Time.current
      }
    end

    def register_fonts(pdf)
      pdf.font_families.update(
        "NotoSans" => {
          normal: FONT_DIR.join("NotoSans-Regular.ttf").to_s,
          bold: FONT_DIR.join("NotoSans-Bold.ttf").to_s
        }
      )
      pdf.font "NotoSans"
    end

    def record_page(pdf)
      pdf.text "RealtorIQ by KGen", size: 18, style: :bold
      pdf.move_down 6
      pdf.text "Record of acceptance", size: 12.5, style: :bold
      pdf.move_down 12
      rows.each do |label, value|
        pdf.text "<b>#{inline(label)}</b>", inline_format: true, size: 9.5
        pdf.text inline(value), inline_format: true, size: 9.5
        pdf.move_down 6
      end
    end

    def rows
      [
        [ "Reference", application.reference ],
        [ "Firm", firm_line ],
        [ "Accepted by", "#{application.applicant_name}, #{application.applicant_designation}" ],
        [ "Mobile", verified_line(application.mobile, application.mobile_verified_at) ],
        [ "WhatsApp", whatsapp_line ],
        [ "Email", verified_line(application.email, application.email_verified_at) ],
        [ "Accepted at", "#{stamp(acceptance.accepted_at)} (#{acceptance.accepted_at.utc.iso8601})" ],
        [ "IP address", acceptance.ip.to_s ],
        [ "Browser", acceptance.user_agent.to_s ],
        [ "Statement", acceptance.statement ],
        [ "Terms", "#{acceptance.terms_version} #{acceptance.terms_sha256}" ],
        [ "Privacy", "#{acceptance.privacy_version} #{acceptance.privacy_sha256}" ]
      ].tap do |list|
        if application.rera_declared_at.present?
          list.insert(-3, [ "RERA declaration", Onboarding::RERA_DECLARATION ])
        end
      end
    end

    def whatsapp_line
      if application.whatsapp_verified_at.present?
        verified_line(application.whatsapp, application.whatsapp_verified_at)
      else
        "#{application.whatsapp}, not verified"
      end
    end

    def verified_line(value, time)
      "#{value} (verified #{stamp(time)})"
    end

    def document_page(pdf, title, source)
      pdf.text title, size: 18, style: :bold
      pdf.move_down 10
      Markdown.parse(source).each { |block| draw_block(pdf, block) }
    end

    def draw_block(pdf, block)
      pdf.start_new_page if pdf.cursor < 48
      case block.type
      when :h1
        pdf.move_down 8
        pdf.text inline(block.text), inline_format: true, size: 18, style: :bold
      when :h2
        pdf.move_down 8
        pdf.text inline(block.text), inline_format: true, size: 12.5, style: :bold
      when :h3
        pdf.move_down 6
        pdf.text inline(block.text), inline_format: true, size: 11, style: :bold
      when :li
        pdf.indent(12 + (block.depth * 12)) do
          pdf.text "• #{inline(block.text)}", inline_format: true, size: 9.5
        end
      else
        pdf.move_down 4
        pdf.text inline(block.text), inline_format: true, size: 9.5
      end
    end

    def inline(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub(/\*\*(.+?)\*\*/, "<b>\\1</b>")
    end

    def firm_line
      name = [ application.firm_name, application.legal_name.presence ].compact.join(" / ")
      "#{name} / #{Onboarding.entity_label(application.entity_type)}"
    end

    def stamp(time)
      time.in_time_zone("Asia/Kolkata").strftime("%-d %b %Y, %H:%M:%S IST")
    end

    def terms
      Registry.find(:terms, acceptance.terms_version)
    end

    def privacy
      Registry.find(:privacy, acceptance.privacy_version)
    end
  end
end
