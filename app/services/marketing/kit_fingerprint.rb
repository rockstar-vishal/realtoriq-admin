# frozen_string_literal: true

module Marketing
  class KitFingerprint
    def self.call(firm:, project:)
      contacts = FirmContacts.new(firm)
      checksums = project.project_creatives.order(:external_id).pluck(:checksum)
      Digest::SHA256.hexdigest([
        PersonaliseCreative::VERSION,
        firm.name.to_s,
        PersonaliseCreative.logo_checksum(firm),
        contacts.mobile.to_s,
        contacts.whatsapp.to_s,
        firm.rera_number.to_s,
        contacts.authority(project),
        project.turbo_pushed_at&.utc&.iso8601,
        checksums.join(",")
      ].join("\n"))
    end
  end
end
