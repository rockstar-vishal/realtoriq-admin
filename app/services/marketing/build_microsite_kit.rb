# frozen_string_literal: true

require "mustache"
require "zip"

module Marketing
  class BuildMicrositeKit
    def self.call(kit)
      new(kit).call
    end

    def initialize(kit)
      @kit = kit
    end

    def call
      project = Project.unscoped.includes(:builder, :city, :locality, project_typologies: :typology).find(kit.project_id)
      firm = kit.firm
      Dir.mktmpdir("microsite-kit") do |dir|
        FileUtils.mkdir_p(File.join(dir, "assets"))
        FileUtils.mkdir_p(File.join(dir, "creatives"))
        data_builder = KitData.new(project, firm, dir)
        data = data_builder.to_h
        write_templates(dir, data)
        write_copy(dir, data, data_builder)
        write_creatives(dir, project, firm)
        path = File.join(dir, zip_name(project))
        zip(dir, path)
        kit.file.attach(io: File.open(path), filename: zip_name(project), content_type: "application/zip")
      end
      kit.update!(
        status: "ready",
        error_message: nil,
        prepared_on: Time.current.in_time_zone("Asia/Kolkata").to_date,
        fingerprint: KitFingerprint.call(firm: kit.firm, project:)
      )
      purge_older
      kit
    end

    private

    attr_reader :kit

    def write_templates(dir, data)
      %w[index.html privacy.html GUIDE.html].each do |name|
        template = KitData::TEMPLATE_ROOT.join(name).read
        File.write(File.join(dir, name), Mustache.render(template, data))
      end
    end

    def write_copy(dir, data, builder)
      project = data["project"]
      firm = data["firm"]
      lines = [
        project["name"],
        "by #{project["builder"]}",
        [ project["locality"], project["city"] ].compact.join(", "),
        project["address"],
        "",
        project["configurations_text"],
        project["category_text"],
        project["possession_text"],
        project["starting_price_text"]
      ]
      if project["has_configurations"]
        lines << "" << "Configurations"
        project["configurations"].each do |row|
          lines << [ row["name"], row["area_text"], row["price_text"] ].compact.join("    ")
        end
      end
      lines << "" << project["promo_text"] if project["promo_text"].present?
      lines << "" << "Registrations"
      data.dig("rera", "registrations").each do |row|
        lines << [ row["label"], row["number"] ].compact.join(" ")
        url = row_url(row["number"])
        lines << url if url.present?
      end
      lines << ""
      lines << "Marketed by #{firm["name"]} · #{firm["rera_label"]} #{firm["rera_number"]}"
      lines << ""
      lines << builder.disclaimer(data)
      File.write(File.join(dir, "copy.txt"), lines.compact.join("\n") + "\n")
    end

    def row_url(number)
      Registrations.for(Project.unscoped.find(kit.project_id)).find { |row| row["number"] == number }&.dig("maharera_url")
    end

    def write_creatives(dir, project, firm)
      project.project_creatives.active.order(:position, :created_at).each do |creative|
        next if creative.video?
        next unless creative.file.attached?

        write_creative(dir, project, firm, creative)
      end
    end

    def write_creative(dir, project, firm, creative)
      dest = nil
      result = PersonaliseCreative.call(creative:, firm:)
      dest = File.join(dir, "creatives", result.payload[:filename])
      copy_creative(firm, creative, dest)
    rescue StandardError => error
      FileUtils.rm_f(dest) if dest
      KitData.warn_skip(project.code, creative.file.attachment&.id, error)
    end

    def copy_creative(firm, creative, dest)
      stored = PersonalisedCreative.across_firms.find_by(firm_id: firm.id, project_creative_id: creative.id)
      return unless stored&.file&.attached?

      stored.file.blob.open do |file|
        FileUtils.cp(file.path, dest)
      end
    end

    def zip(dir, path)
      Zip::File.open(path, create: true) do |archive|
        Dir.glob(File.join(dir, "**", "*")).sort.each do |file|
          next if File.directory?(file) || file == path

          archive.add(file.delete_prefix("#{dir}/"), file)
        end
      end
    end

    def zip_name(project)
      "#{project.name.to_s.parameterize.presence || "project"}-microsite-kit.zip"
    end

    def purge_older
      MicrositeKit.across_firms.where(firm_id: kit.firm_id, project_id: kit.project_id).where.not(id: kit.id).find_each do |old|
        old.file.purge_later if old.file.attached?
        old.destroy!
      end
    end
  end
end
