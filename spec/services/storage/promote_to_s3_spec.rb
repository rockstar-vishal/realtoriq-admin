# frozen_string_literal: true

require "rails_helper"

RSpec.describe Storage::PromoteToS3 do
  def blob_with_file(bytes = "hello")
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes), filename: "grove-goregaon-banner.jpg", content_type: "image/jpeg"
    )
  end

  it "copies the file onto the destination service and repoints the blob" do
    blob = blob_with_file
    destination = instance_double(ActiveStorage::Service)
    expect(destination).to receive(:upload) do |key, io, **opts|
      expect(key).to eq(blob.key)
      expect(io.read).to eq("hello")
      expect(opts[:checksum]).to eq(blob.checksum)
    end

    result = described_class.call(
      blob:, source: blob.service, destination:, destination_name: "amazon"
    )

    expect(result).to eq(:promoted)
    expect(blob.reload.service_name).to eq("amazon")
  end

  it "does not repoint a blob whose file is missing" do
    blob = blob_with_file
    File.delete(blob.service.path_for(blob.key))
    destination = instance_double(ActiveStorage::Service)
    expect(destination).not_to receive(:upload)

    result = described_class.call(
      blob:, source: blob.service, destination:, destination_name: "amazon"
    )

    expect(result).to eq(:missing)
    expect(blob.reload.service_name).to eq("test")
  end
end
