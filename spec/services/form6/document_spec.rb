# frozen_string_literal: true

require "rails_helper"
require "zip"
require "rexml/document"

RSpec.describe Form6::Document do
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:locality) { create(:locality, city:, name: "Bandra") }
  let(:firm) do
    create(:firm, name: "Aarav Realty", legal_name: "Aarav Realty Private Limited", city:, locality:,
      address_line1: "12 Linking Road", address_line2: "Off Turner", pincode: "400050",
      rera_number: "A51900012345")
  end
  let(:period) { Form6::Period.parse("2026-04") }
  let(:today) { Date.new(2026, 10, 24) }

  before { Current.firm = firm }

  def tables(xml)
    document = REXML::Document.new(xml)
    REXML::XPath.match(document, "//*[local-name()='tbl']").map do |table|
      REXML::XPath.match(table, "./*[local-name()='tr']").map do |row|
        REXML::XPath.match(row, "./*[local-name()='tc']").map do |cell|
          REXML::XPath.match(cell, ".//*[local-name()='t']").map(&:text).join
        end
      end
    end
  end

  def open_docx(binary)
    xml = nil
    Zip::File.open_buffer(binary) do |zip|
      expect(zip.entries.map(&:name)).to include(
        "[Content_Types].xml", "word/document.xml", "word/styles.xml", "word/settings.xml"
      )
      # open_buffer returns its buffer, not the block's value.
      xml = zip.read("word/document.xml").force_encoding(Encoding::UTF_8)
    end
    xml
  end

  def body_paragraphs(xml)
    document = REXML::Document.new(xml)
    REXML::XPath.match(document, "//*[local-name()='body']/*[local-name()='p']")
  end

  def cell_text(cell)
    cell.scan(%r{<w:t[^>]*>([^<]*)</w:t>}).flatten.join
  end

  def paragraph_text(node)
    REXML::XPath.match(node, ".//*[local-name()='t']").map { |text| text.text.to_s }.join
  end

  def run_texts(node, bold:)
    REXML::XPath.match(node, "./*[local-name()='r']").filter_map do |run|
      is_bold = REXML::XPath.match(run, "./*[local-name()='rPr']/*[local-name()='b']").any?
      next if is_bold != bold

      REXML::XPath.match(run, ".//*[local-name()='t']").map { |text| text.text.to_s }.join
    end
  end

  it "names the file from the firm and the half-year" do
    expect(described_class.filename_for(firm:, period:)).to eq("Form6_Aarav-Realty_Apr-Sep-2026.docx")
    blank = build(:firm, name: "---")
    october = Form6::Period.parse("2025-10")
    expect(described_class.filename_for(firm: blank, period: october)).to eq("Form6_Firm_Oct-2025-Mar-2026.docx")
  end

  it "fills the official tables and escapes every value" do
    tower = create(:project, firm:, name: "Tower & <View>", rera_number: nil)
    gamma = create(:project, firm:, name: "Gamma Homes", rera_number: "P51800000002")
    alpha = create(:project, firm:, name: "Alpha One", rera_number: "P51800000001")
    typology = create(:typology, name: "2 BHK", category: "residential")
    configuration = create(:project_typology, project: gamma, typology:, label: "Ultima")
    firm.update!(form6: {
      "registered_name" => "KGen Agents",
      "competency_certificate_no" => "CC-100",
      "signatory_name" => "Aarav Sethi",
      "signatory_designation" => "Partner",
      "designated_project_ids" => [ alpha.id, tower.id ],
      "turnover_20l_or_more" => true,
      "principal_officer" => {
        "name" => "Priya Shah", "appointed_on" => "2024-01-15",
        "mobile" => "+919876543210", "email" => "priya@example.com", "address" => "1 Marine Drive"
      },
      "designated_director" => {
        "name" => "Dev Kapoor", "appointed_on" => "2024-02-01",
        "mobile" => "+919123456789", "email" => "dev@example.com", "address" => "2 Marine Drive"
      }
    })
    create(:booking, firm:, project: tower, unit_no: "B-1104", customer_name: "Rhea Kapoor",
      booked_on: Date.new(2026, 4, 2), agreement_value: 10_000_000, commission_percent: 2,
      kicker: 50_000, passback: 66_000)
    create(:booking, firm:, project: gamma, project_typology: configuration, unit_no: "1204",
      customer_name: "Meera Shah", booked_on: Date.new(2026, 5, 1), agreement_value: 1_000_000,
      commission_percent: 1, kicker: 0, passback: 0)
    create(:booking, :cancelled, firm:, project: tower, unit_no: "B-1105", booked_on: Date.new(2026, 6, 1))
    create(:booking, firm:, project: nil, unit_no: nil, booked_on: Date.new(2026, 6, 2))
    create(:booking, firm:, project: tower, unit_no: "B-1106", booked_on: Date.new(2026, 10, 2))

    xml = open_docx(described_class.new(firm:, period:, today:).to_docx)
    rows = tables(xml)
    lines = body_paragraphs(xml).map { |node| paragraph_text(node) }

    expect(xml).to include("ANNEXURE \u2018A\u2019")
    expect(xml).to include("FORM 6")
    expect(xml).to include("DISCLOSURE OF REAL ESTATE TRANSACTIONS FACILITATED AND OTHER PARTICULARS")
    expect(xml).to include("(MahaRERA registered real estate agent shall be in public view except the portion marked *)")
    expect(xml).not_to include("On the letterhead")
    expect(xml).to include("Aarav Realty")
    expect(xml).to include("12 Linking Road, Off Turner, Bandra, Mumbai, 400050")
    expect(xml).to include("MahaRERA A51900012345")
    expect(lines).to include("Date: 24/10/2026")
    expect(lines).to include("Name: KGen Agents")
    expect(lines).not_to include("Name: Aarav Realty Private Limited")
    expect(lines).to include("Maharera Registration No. : A51900012345")
    expect(lines).to include("Maharera Real Estate Agent Certificate of Competency No. : CC-100")
    expect(lines).to include("Information for the period commencing from 01/04/2026 to 30/09/2026")
    expect(xml).to include('w:w="11906"')
    expect(xml).to include('w:h="16838"')
    expect(xml).to include('w:orient="portrait"')
    expect(xml).to include('w:top="1440"')
    expect(xml).to include('w:left="1440"')
    expect(xml).to include("Segoe UI")
    expect(xml).to include("Tower &amp; &lt;View&gt;")
    expect(xml).not_to include("Tower &amp;amp;")

    expect(rows[0][0]).to eq([ "S. No.", "Name of the Project", "MahaRERA Project Registration Number" ])
    expect(rows[0][1]).to eq([ "1", "Alpha One", "P51800000001" ])
    expect(rows[0][2]).to eq([ "2", "Tower & <View>", "" ])
    expect(rows[1][0]).to eq(Form6::Document::TABLE_B_HEADERS)
    expect(rows[1][1]).to eq([
      "1", "Tower & <View>", "", "", "", "B-1104", "02/04/2026", "2,50,000"
    ])
    expect(rows[1][2]).to eq([
      "2", "Gamma Homes", "P51800000002", "Apartment", "Residential", "1204", "01/05/2026", "10,000"
    ])
    expect(rows[1].size).to eq(3)
    expect(rows[2][0]).to eq([ "", "Name", "Date of appointment", "Mobile Number", "Email Address", "Contact Address" ])
    expect(rows[2][1]).to eq([
      "Principal Officer", "Priya Shah", "15/01/2024", "+91 98765 43210", "priya@example.com", "1 Marine Drive"
    ])
    expect(rows[2][2]).to eq([
      "Designated Director", "Dev Kapoor", "01/02/2024", "+91 91234 56789", "dev@example.com", "2 Marine Drive"
    ])
    expect(xml).to include("Signature of Agent")
    expect(xml).to include("Seal/Rubber Stamp:")

    date = body_paragraphs(xml).find { |node| paragraph_text(node).start_with?("Date:") }
    expect(run_texts(date, bold: true)).to include("Date: ")
    expect(run_texts(date, bold: false)).to include("24/10/2026")
    expect(xml).to include('w:jc w:val="right"')
    expect(xml).to include('w:sz w:val="22"')

    registration = body_paragraphs(xml).find { |node| paragraph_text(node).include?("Maharera Registration No.") }
    expect(run_texts(registration, bold: true).join).to include("Maharera Registration No. :")
    expect(run_texts(registration, bold: false)).to include("A51900012345")

    competency = body_paragraphs(xml).find { |node|
      paragraph_text(node).include?("Certificate of Competency")
    }
    expect(run_texts(competency, bold: true).join).to include("Certificate of Competency No. :")
    expect(run_texts(competency, bold: false)).to include("CC-100")

    period_line = body_paragraphs(xml).find { |node| paragraph_text(node).include?("period commencing") }
    expect(run_texts(period_line, bold: true).join).to include("Information for the period commencing from ")
    expect(run_texts(period_line, bold: false)).to include("01/04/2026", "30/09/2026")

    expect(xml).to include('w:before="240"')
    expect(xml).to include('w:after="120"')
    expect(xml).to include('<w:u w:val="single"/>')

    cells = xml.scan(%r{<w:tc>.*?</w:tc>}m)
    date_cell = cells.find { |cell| cell_text(cell) == "02/04/2026" }
    expect(date_cell).to include("<w:noWrap/>")
    expect(date_cell).to include('w:w="1250"')
    expect(date_cell).to include('w:val="18"')
    expect(cells.find { |cell| cell_text(cell) == "2,50,000" }).to include("<w:noWrap/>")
    expect(cells.find { |cell| cell_text(cell) == "Residential" }).to include("<w:noWrap/>")
    expect(cells.find { |cell| cell_text(cell) == "1204" }).to include("<w:noWrap/>")
    expect(cells.find { |cell| cell_text(cell) == "P51800000002" }).to include("<w:noWrap/>")
    expect(cells.find { |cell| cell_text(cell) == "P51800000001" }).to include("<w:noWrap/>")
    widths = xml.scan(%r{<w:tblGrid>(.*?)</w:tblGrid>}m)[1].first.scan(/w:w="(\d+)"/).flatten.map(&:to_i)
    expect(widths).to eq([ 500, 1450, 1400, 1100, 1250, 926, 1250, 1150 ])
    expect(widths.sum).to eq(9026)
    expect(xml).not_to include('w:val="20"')

    paragraphs = body_paragraphs(xml)
    signature = paragraphs.index { |node| paragraph_text(node) == "Signature of Agent" }
    expect(paragraph_text(paragraphs[signature + 1])).to eq("")
    expect(paragraph_text(paragraphs[signature + 2])).to eq("")
    expect(paragraph_text(paragraphs[signature + 3])).to eq("")
    name_line = paragraphs[signature + 4]
    designation_line = paragraphs[signature + 5]
    seal_line = paragraphs[signature + 6]
    expect(paragraph_text(name_line)).to eq("Name: Aarav Sethi")
    expect(paragraph_text(designation_line)).to eq("Designation: Partner")
    expect(paragraph_text(seal_line)).to eq("Seal/Rubber Stamp: ")
    expect(run_texts(name_line, bold: true)).to include("Name: ")
    expect(run_texts(name_line, bold: false)).to include("Aarav Sethi")
    expect(run_texts(designation_line, bold: true)).to include("Designation: ")
    expect(run_texts(designation_line, bold: false)).to include("Partner")
    expect(run_texts(seal_line, bold: true).join).to include("Seal/Rubber Stamp:")
    expect(run_texts(seal_line, bold: false).join).to eq("")
    expect(xml).to include('w:left="5000"')
    expect(paragraphs[signature].to_s).to include("<w:b/>")
    expect(xml).not_to include('w:val="16"')

    xml.scan(%r{<w:tbl>.*?</w:tbl>}m).each do |table|
      rows = table.scan(%r{<w:tr>.*?</w:tr>}m)
      expect(rows).to all(include("<w:cantSplit/>"))
      expect(rows.first).to include("<w:tblHeader/>")
      expect(rows.drop(1).any? { |row| row.include?("<w:tblHeader/>") }).to be(false)
    end
    expect(xml.scan("<w:tblHeader/>").size).to eq(3)

    table_b_title = xml[%r{<w:p>\s*<w:pPr>.*?Table B:.*?</w:p>}m]
    expect(table_b_title).to include("<w:keepNext/>")
    signature_xml = xml[%r{<w:p>\s*<w:pPr>.*?Signature of Agent.*?</w:p>}m]
    expect(signature_xml).to include("<w:keepNext/>", "<w:keepLines/>")
  end

  it "leaves three blank rows, and Table C blank, when there is nothing to report" do
    firm.update!(form6: {
      "turnover_20l_or_more" => false,
      "principal_officer" => { "name" => "Should Not Show" }
    })

    rows = tables(open_docx(described_class.new(firm:, period:, today:).to_docx))

    expect(rows[0].size).to eq(4)
    expect(rows[0][1]).to eq([ "", "", "" ])
    expect(rows[0][3]).to eq([ "", "", "" ])
    expect(rows[1].size).to eq(4)
    expect(rows[1][1]).to eq(Array.new(8, ""))
    expect(rows[2][1]).to eq([ "Principal Officer", "", "", "", "", "" ])
    expect(rows[2][2]).to eq([ "Designated Director", "", "", "", "", "" ])
  end
end
