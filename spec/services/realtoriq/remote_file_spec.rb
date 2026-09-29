# frozen_string_literal: true

require "rails_helper"

RSpec.describe Realtoriq::RemoteFile do
  before do
    allow(Realtoriq::Credentials).to receive(:turbo_public_origin).and_return("https://launch.example")
    allow(Realtoriq::Credentials).to receive(:turbo_api_origin).and_return("https://launch.example")
  end

  def stub_http(response)
    http = Object.new
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  def response(code:, type: "image/jpeg", body: "abc", location: nil)
    headers = { "content-type" => type, "location" => location }
    Struct.new(:code, :headers, :body) do
      def [](key) = headers[key]

      def read_body
        yield body
      end
    end.new(code, headers, body)
  end

  it "refuses a host that is not LaunchIQ or S3" do
    expect { described_class.fetch("https://evil.example/a.jpg", content_types: described_class::IMAGE_TYPES) }
      .to raise_error(described_class::Error, "file host is not allowed")
  end

  it "refuses a file that is too large or the wrong type" do
    stub_const("Realtoriq::RemoteFile::MAX_BYTES", 4)
    stub_http(response(code: "200", body: "12345"))

    expect { described_class.fetch("https://launch.example/a.jpg", content_types: described_class::IMAGE_TYPES) }
      .to raise_error(described_class::Error, "file is too large")

    stub_const("Realtoriq::RemoteFile::MAX_BYTES", 20.megabytes)
    stub_http(response(code: "200", type: "text/html", body: "nope"))
    expect { described_class.fetch("https://launch.example/a.jpg", content_types: described_class::IMAGE_TYPES) }
      .to raise_error(described_class::Error, "file type is not allowed")
  end

  it "follows a redirect onto the S3 host" do
    first = response(code: "302", location: "https://kgen-presales.s3.ap-south-1.amazonaws.com/a.jpg")
    second = response(code: "200", body: "picture")
    calls = 0
    http = Object.new
    http.define_singleton_method(:request) do |_request, &block|
      calls += 1
      block.call(calls == 1 ? first : second)
    end
    allow(Net::HTTP).to receive(:start).and_yield(http)

    file = described_class.fetch("https://launch.example/redirect", content_types: described_class::IMAGE_TYPES)
    expect(file.read).to eq("picture")
    file.close!
  end
end
