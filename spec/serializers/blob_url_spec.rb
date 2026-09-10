# frozen_string_literal: true

require "rails_helper"

# Rails serves blobs from ActiveStorage::Blobs::RedirectController, which has no
# authentication. A permanent URL for a booking document or a collection proof
# is therefore a permanent *unauthenticated* URL — anyone it is forwarded to
# keeps access for good, and revoking means deleting the file.
RSpec.describe Api::V1::BlobUrl do
  let(:firm) { create(:firm) }
  let(:lead) { create(:lead, firm:) }
  let(:booking) { create(:booking, firm:, lead:) }

  # The signed id is base64 JSON before the "--" signature.
  def signed_payload(url)
    JSON.parse(Base64.decode64(url[%r{blobs/redirect/([^/]+)/}, 1].split("--").first))["_rails"]
  end

  def attach(record, name)
    record.public_send(name).attach(
      io: StringIO.new("hello"), filename: "proof.pdf", content_type: "application/pdf"
    )
    record.public_send(name)
  end

  around do |example|
    ActiveStorage::Current.url_options = { host: "https://example.com" }
    example.run
    ActiveStorage::Current.url_options = nil
  end

  it "returns nil for a missing attachment" do
    expect(described_class.call(nil)).to be_nil
  end

  describe ".sensitive" do
    # Comparing the decoded payloads rather than the URL strings: the whole
    # difference is one `exp` claim inside the signed id, and a string compare
    # says nothing about which one carries it.
    it "puts an expiry in the signed id, where the permanent one has none" do
      collection = create(:collection, firm:, booking:)
      proof = attach(collection, :proof)

      expect(signed_payload(described_class.sensitive(proof))).to have_key("exp")
      expect(signed_payload(described_class.call(proof))).not_to have_key("exp")
    end

    # Regression: the first version of this built its options hash with
    # `ActiveStorage::Current.url_options.presence.to_h`, and Hash#to_h returns
    # self — so setting expires_in on it wrote through to Current, and every
    # later URL in the same request silently started expiring too. Photos would
    # have gone with it.
    it "does not leak the expiry into later calls" do
      collection = create(:collection, firm:, booking:)
      proof = attach(collection, :proof)

      described_class.sensitive(proof)

      expect(ActiveStorage::Current.url_options).not_to have_key(:expires_in)
      expect(signed_payload(described_class.call(proof))).not_to have_key("exp")
    end

    it "produces a URL that stops working once it expires" do
      collection = create(:collection, firm:, booking:)
      proof = attach(collection, :proof)

      signed_id = described_class.sensitive(proof)[%r{blobs/redirect/([^/]+)/}, 1]
      expect(ActiveStorage::Blob.find_signed(signed_id)).to be_present

      travel(described_class::SENSITIVE_TTL + 1.minute) do
        expect(ActiveStorage::Blob.find_signed(signed_id)).to be_nil
      end
    end

    it "leaves the permanent URL working, which is what photos rely on" do
      property = create(:property, firm:)
      property.photos.attach(
        io: StringIO.new("x"), filename: "flat.png", content_type: "image/png"
      )
      photo = property.photos.attachments.first

      signed_id = described_class.call(photo)[%r{blobs/redirect/([^/]+)/}, 1]

      travel(described_class::SENSITIVE_TTL + 1.day) do
        # `shareable` exists so a broker can paste a photo link into WhatsApp;
        # that link has to outlive the response.
        expect(ActiveStorage::Blob.find_signed(signed_id)).to be_present
      end
    end
  end

  describe "what the serializers emit" do
    it "gives a collection proof an expiring URL" do
      collection = create(:collection, firm:, booking:)
      attach(collection, :proof)

      url = Api::V1::CollectionSerializer.call(collection.reload)[:proof_url]
      signed_id = url[%r{blobs/redirect/([^/]+)/}, 1]

      travel(described_class::SENSITIVE_TTL + 1.minute) do
        expect(ActiveStorage::Blob.find_signed(signed_id)).to be_nil
      end
    end

    it "gives a booking document an expiring URL" do
      # The file is required, so it has to be attached before the save.
      document = booking.booking_documents.new(
        firm:, slot: "other", uploaded_by_user: create(:user, firm:)
      )
      attach(document, :file)
      document.save!

      url = Api::V1::BookingSerializer.detail(booking.reload)[:documents].first[:url]
      signed_id = url[%r{blobs/redirect/([^/]+)/}, 1]

      travel(described_class::SENSITIVE_TTL + 1.minute) do
        expect(ActiveStorage::Blob.find_signed(signed_id)).to be_nil
      end
      expect(document).to be_persisted
    end
  end
end
