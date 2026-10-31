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
        checksums.join(","),
        active_key(project)
      ].join("\n"))
    end

    # Active creative ids and each Valid Until date, read when the kit is
    # requested. A creative that expires overnight changes the fingerprint
    # even when LaunchIQ has not pushed again.
    def self.active_key(project)
      project.project_creatives.active.order(:id).pluck(:id, :valid_until).map { |id, date|
        "#{id}:#{date&.iso8601}"
      }.join(",")
    end
  end
end
