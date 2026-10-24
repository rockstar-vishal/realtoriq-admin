# frozen_string_literal: true

namespace :photos do
  desc "Build thumb and large WebP copies of existing project and property photos. Safe to re-run."
  task variants: :environment do
    built = 0
    skipped = 0
    failed = []
    counts = { "Project" => 0, "Property" => 0 }

    Current.set(firm_scope_bypassed: true) do
      [ Project, Property ].each do |model|
        model.unscoped.in_batches(of: 50) do |relation|
          relation.includes(photos_attachments: :blob).each do |record|
            record.photos.attachments.each do |attachment|
              counts[model.name] += 1
              blob = attachment.blob
              unless blob&.variable?
                skipped += 1
                next
              end

              %i[thumb large].each do |name|
                attachment.variant(name).processed
                built += 1
              rescue StandardError
                failed << blob.id
              end
            end
          end
        end
      end
    end

    failed_ids = failed.uniq
    puts "project_photos=#{counts['Project']} property_photos=#{counts['Property']} variants_built=#{built} skipped=#{skipped} failed=#{failed_ids.size}"
    failed_ids.each { |id| puts "failed_blob=#{id}" }
  end
end
