# frozen_string_literal: true

module Marketing
  # The text a broker pastes with a video link. The lines are the same firm
  # details and authority labels the footer prints.
  class VideoShareText
    def self.call(creative:, project:, firm:)
      new(creative:, project:, firm:).call
    end

    def initialize(creative:, project:, firm:)
      @creative = creative
      @project = project
      @firm = firm
    end

    def call
      return if Eligibility.reason(firm)

      lines = [
        "#{project.name}: #{creative.title}",
        "Watch: #{creative.video_url}",
        "#{firm.name} · #{contacts.call_line}"
      ]
      lines << "#{authority} Agent Reg. No. #{firm.rera_number}"
      lines << contacts.project_line(numbers) if numbers.any?
      lines.join("\n")
    end

    private

    attr_reader :creative, :project, :firm

    def contacts
      @contacts ||= FirmContacts.new(firm)
    end

    def authority
      Authorities.for(project).fetch("authority")
    end

    def numbers
      Array(creative.registration_numbers).map { |number| number.to_s.strip }.reject(&:blank?)
    end
  end
end
