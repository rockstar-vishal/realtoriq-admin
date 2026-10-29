# frozen_string_literal: true

module Marketing
  # State RERA sites we know. An unknown state still says RERA, with no link.
  module Authorities
    KNOWN = {
      "maharashtra" => [ "MahaRERA", "maharera.maharashtra.gov.in", "https://maharera.maharashtra.gov.in" ],
      "karnataka" => [ "RERA", "rera.karnataka.gov.in", "https://rera.karnataka.gov.in" ],
      "gujarat" => [ "RERA", "gujrera.gujarat.gov.in", "https://gujrera.gujarat.gov.in" ],
      "delhi" => [ "RERA", "rera.delhi.gov.in", "https://rera.delhi.gov.in" ],
      "haryana" => [ "RERA", "haryanarera.gov.in", "https://haryanarera.gov.in" ],
      "uttar pradesh" => [ "RERA", "www.up-rera.in", "https://www.up-rera.in" ],
      "tamil nadu" => [ "RERA", "rera.tn.gov.in", "https://rera.tn.gov.in" ],
      "telangana" => [ "RERA", "rera.telangana.gov.in", "https://rera.telangana.gov.in" ],
      "rajasthan" => [ "RERA", "rera.rajasthan.gov.in", "https://rera.rajasthan.gov.in" ],
      "madhya pradesh" => [ "RERA", "rera.mp.gov.in", "https://rera.mp.gov.in" ],
      "west bengal" => [ "RERA", "rera.wb.gov.in", "https://rera.wb.gov.in" ],
      "goa" => [ "RERA", "rera.goa.gov.in", "https://rera.goa.gov.in" ],
      "kerala" => [ "RERA", "rera.kerala.gov.in", "https://rera.kerala.gov.in" ],
      "punjab" => [ "RERA", "rera.punjab.gov.in", "https://rera.punjab.gov.in" ]
    }.freeze

    def self.for(project)
      row = KNOWN[project&.city&.state.to_s.strip.downcase]
      if row
        { "authority" => row[0], "website" => row[1], "website_url" => row[2] }
      else
        { "authority" => "RERA", "website" => nil, "website_url" => nil }
      end
    end
  end
end
