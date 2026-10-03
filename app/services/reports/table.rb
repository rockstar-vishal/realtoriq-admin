# frozen_string_literal: true

module Reports
  class Table
    def self.csv(kind, payload)
      case kind
      when :source_status then source_status(payload)
      when :dead_leads then dead_leads(payload)
      when :bookings then bookings(payload)
      when :revenue then revenue(payload)
      end
    end

    def self.filename(kind, payload)
      "#{kind.to_s.tr('_', '-')}-#{payload[:from]}-to-#{payload[:upto]}.csv"
    end

    def self.source_status(payload)
      headers = [ "Source", *payload[:columns].map { |column| column[:name] }, "Total" ]
      rows = payload[:rows].map do |row|
        [ row[:source][:name], *payload[:columns].map { |column| row[:counts][column[:code]] }, row[:total] ]
      end
      rows << [ "All sources", *payload[:columns].map { |column| payload[:summary][:counts][column[:code]] }, payload[:summary][:total] ]
      Csv.generate(headers, rows)
    end

    def self.dead_leads(payload)
      headers = [ "Month", "Generated", "Dead", "Rate", *payload[:sources].map { |source| source[:name] } ]
      rows = payload[:rows].map { |row| dead_row(row, payload[:sources]) }
      rows << dead_row(payload[:summary].merge(label: "Total"), payload[:sources])
      Csv.generate(headers, rows)
    end

    def self.dead_row(row, sources)
      rate = row[:rate].nil? ? "" : "#{row[:rate]}%"
      [
        row[:label], row[:generated], row[:dead], rate,
        *sources.map { |source| row[:by_source][Catalog.source_key(source[:id])] }
      ]
    end

    def self.bookings(payload)
      headers = [ "Month", "Bookings", "Cancelled", "Live", "Total AV", "Invoices", "Collections" ]
      rows = payload[:rows].map { |row| booking_row(row[:label], row) }
      rows << booking_row("Total", payload[:summary])
      Csv.generate(headers, rows)
    end

    def self.booking_row(label, row)
      [ label, row[:bookings], row[:cancelled], row[:live], row[:agreement_value], row[:invoices], row[:collections] ]
    end

    def self.revenue(payload)
      headers = [ "Month", "Total AV", "Revenue", "Invoiced", "Collected", "Outstanding" ]
      rows = payload[:rows].map { |row| revenue_row(row[:label], row) }
      rows << revenue_row("Total", payload[:summary])
      Csv.generate(headers, rows)
    end

    def self.revenue_row(label, row)
      [ label, row[:agreement_value], row[:net_income], row[:invoiced], row[:collected], row[:outstanding] ]
    end
  end
end
