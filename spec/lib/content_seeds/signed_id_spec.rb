require "rails_helper"
require "content_seeds/signed_id"
require "content_seeds/tokens"

def legacy_message_envelope(payload, purpose:)
  message = Base64.urlsafe_encode64(payload, padding: false)
  outer = { "_rails" => { "message" => message, "exp" => nil, "pur" => purpose }}.to_json
  "#{Base64.urlsafe_encode64(outer, padding: false)}--deadbeef"
end

describe ContentSeeds::SignedId do
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "a.png",
                                           content_type: "image/png")
  end

  describe ".blob_id" do
    it "recovers the id from a real signed_id, without the secret" do
      expect(ContentSeeds::SignedId.blob_id(blob.signed_id)).to eq(blob.id)
    end

    it "accepts a url-safe base64 alphabet" do
      urlsafe_token = blob.signed_id.split("--").then { |body, hmac| "#{body.tr("+/", "-_")}--#{hmac}" }

      expect(ContentSeeds::SignedId.blob_id(urlsafe_token)).to eq(blob.id)
    end

    it "returns nil for a token signed for another purpose" do
      other_purpose_token = blob.signed_id(purpose: :something_else)

      expect(ContentSeeds::SignedId.blob_id(other_purpose_token)).to be(nil)
    end

    it "returns nil for garbage input" do
      expect(ContentSeeds::SignedId.blob_id("not-a-token")).to be(nil)
      expect(ContentSeeds::SignedId.blob_id(nil)).to be(nil)
      expect(ContentSeeds::SignedId.blob_id("")).to be(nil)
    end

    it "recovers the id from the legacy nested `message` envelope" do
      token = legacy_message_envelope(blob.id.to_json, purpose: "blob_id")

      expect(ContentSeeds::SignedId.blob_id(token)).to eq(blob.id)
    end

    it "never deserializes a Marshal payload, and returns nil instead" do
      token = legacy_message_envelope(Marshal.dump(blob.id), purpose: "blob_id")

      expect(ContentSeeds::SignedId.blob_id(token)).to be(nil)
    end
  end

  describe ".variation" do
    it "recovers the transformations from a real variation token, without the secret" do
      token = ActiveStorage::Variation.encode(resize: "800>")

      expect(ContentSeeds::SignedId.variation(token)).to eq("resize" => "800>")
    end

    it "returns nil for a token signed for another purpose" do
      expect(ContentSeeds::SignedId.variation(blob.signed_id)).to be(nil)
    end

    it "returns nil when the decoded data isn't a hash" do
      token = legacy_message_envelope(42.to_json, purpose: "variation")

      expect(ContentSeeds::SignedId.variation(token)).to be(nil)
    end
  end
end

describe ContentSeeds::Tokens do
  include Rails.application.routes.url_helpers

  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "a.png",
                                           content_type: "image/png")
  end
  let(:pdf_blob) do
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-"), filename: "a.pdf",
                                           content_type: "application/pdf")
  end

  describe ".referenced_blob_ids" do
    it "collects blob ids from both blob and representation urls" do
      other_blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("x"), filename: "b.png", content_type: "image/png"
      )
      variant_path = rails_representation_path(
        other_blob.variant(resize_to_limit: [800, nil]), only_path: true
      )
      html = %(<img src="#{rails_blob_path(blob, only_path: true)}"><img src="#{variant_path}">)

      expect(ContentSeeds::Tokens.referenced_blob_ids(html)).to contain_exactly(blob.id, other_blob.id)
    end

    it "returns an empty array for blank html" do
      expect(ContentSeeds::Tokens.referenced_blob_ids(nil)).to eq([])
      expect(ContentSeeds::Tokens.referenced_blob_ids("")).to eq([])
    end
  end

  describe ".to_tokens" do
    it "rewrites a blob url into a consul-seed token" do
      html = %(<a href="#{rails_blob_path(blob, only_path: true)}">download</a>)

      rewritten, unresolved = ContentSeeds::Tokens.to_tokens(html, id_to_key: { blob.id => blob.key })

      expect(rewritten).to eq(%(<a href="consul-seed://blob/#{blob.key}">download</a>))
      expect(unresolved).to be_empty
    end

    it "rewrites a representation url into a consul-seed token carrying the variant" do
      variant_path = rails_representation_path(blob.variant(resize_to_limit: [800, nil]), only_path: true)
      html = %(<img src="#{variant_path}">)

      rewritten, unresolved = ContentSeeds::Tokens.to_tokens(html, id_to_key: { blob.id => blob.key })

      expect(rewritten).to match(%r{\A<img src="consul-seed://blob/#{blob.key}\?variant=[\w-]+">\z})
      expect(unresolved).to be_empty

      encoded_variant = rewritten[/variant=([\w-]+)/, 1]
      transformations = JSON.parse(Base64.urlsafe_decode64(encoded_variant))
      expect(transformations["resize_to_limit"]).to eq([800, nil])
    end

    it "preserves the disposition=attachment query param" do
      html = rails_blob_path(blob, disposition: "attachment", only_path: true)

      rewritten, unresolved = ContentSeeds::Tokens.to_tokens(html, id_to_key: { blob.id => blob.key })

      expect(rewritten).to eq("consul-seed://blob/#{blob.key}?disposition=attachment")
      expect(unresolved).to be_empty
    end

    it "leaves the url untouched and reports it when the blob id isn't in id_to_key" do
      html = rails_blob_path(blob, only_path: true)

      rewritten, unresolved = ContentSeeds::Tokens.to_tokens(html, id_to_key: {})

      expect(rewritten).to eq(html)
      expect(unresolved).to eq([html])
    end

    it "leaves the url untouched and reports it when the signed id is undecodable (Marshal-era)" do
      undecodable = legacy_message_envelope(Marshal.dump(blob.id), purpose: "blob_id")
      html = "/rails/active_storage/blobs/redirect/#{undecodable}/a.png"

      rewritten, unresolved = ContentSeeds::Tokens.to_tokens(html, id_to_key: { blob.id => blob.key })

      expect(rewritten).to eq(html)
      expect(unresolved).to eq([html])
    end

    it "returns the html untouched for blank input" do
      expect(ContentSeeds::Tokens.to_tokens(nil, id_to_key: {})).to eq([nil, []])
    end
  end

  describe ".from_tokens" do
    it "rewrites a plain blob token into a freshly signed blob path" do
      html = "<a href=\"consul-seed://blob/#{blob.key}\">download</a>"

      rewritten, unresolved = ContentSeeds::Tokens.from_tokens(html)

      expect(rewritten).to eq(%(<a href="#{rails_blob_path(blob, only_path: true)}">download</a>))
      expect(unresolved).to be_empty
    end

    it "rewrites a variant token into a freshly signed representation path" do
      encoded = Base64.urlsafe_encode64({ "resize_to_limit" => [800, nil] }.to_json, padding: false)
      html = "<img src=\"consul-seed://blob/#{blob.key}?variant=#{encoded}\">"

      rewritten, unresolved = ContentSeeds::Tokens.from_tokens(html)

      expected = rails_representation_path(blob.variant(resize_to_limit: [800, nil]), only_path: true)
      expect(rewritten).to eq(%(<img src="#{expected}">))
      expect(unresolved).to be_empty
    end

    it "preserves the disposition=attachment query param" do
      html = "consul-seed://blob/#{blob.key}?disposition=attachment"

      rewritten, unresolved = ContentSeeds::Tokens.from_tokens(html)

      expect(rewritten).to eq("#{rails_blob_path(blob, only_path: true)}?disposition=attachment")
      expect(unresolved).to be_empty
    end

    it "leaves the token untouched and reports it when the key is unknown" do
      html = "consul-seed://blob/doesnotexist12345678901234"

      rewritten, unresolved = ContentSeeds::Tokens.from_tokens(html)

      expect(rewritten).to eq(html)
      expect(unresolved).to eq([html])
    end

    it "falls back to a plain blob path and reports it when the blob isn't representable" do
      encoded = Base64.urlsafe_encode64({ "resize_to_limit" => [800, nil] }.to_json, padding: false)
      html = "consul-seed://blob/#{pdf_blob.key}?variant=#{encoded}"

      rewritten, unresolved = ContentSeeds::Tokens.from_tokens(html)

      expect(rewritten).to eq(rails_blob_path(pdf_blob, only_path: true))
      expect(unresolved).not_to be_empty
    end

    it "returns the html untouched for blank input" do
      expect(ContentSeeds::Tokens.from_tokens(nil)).to eq([nil, []])
    end
  end
end

describe ContentSeeds::Tokens, "url shapes found in real content" do
  let(:blob) do
    ActiveStorage::Blob.create_before_direct_upload!(filename: "f.pdf", byte_size: 1, checksum: "x")
  end
  let(:id_to_key) { { blob.id => blob.key } }

  it "swallows the scheme and host of an absolute editor url instead of leaving them glued to the token" do
    html = %(<a href="http://source.example/rails/active_storage/blobs/redirect/#{blob.signed_id}/f.pdf">PDF</a>)

    rewritten, unresolved = ContentSeeds::Tokens.to_tokens(html, id_to_key: id_to_key)

    expect(rewritten).to eq(%(<a href="consul-seed://blob/#{blob.key}">PDF</a>))
    expect(unresolved).to be_empty
  end

  it "stops at angle brackets so a url in an unquoted attribute or in text keeps the markup after it" do
    html = %(<a href=/rails/active_storage/blobs/redirect/#{blob.signed_id}/informe.pdf>Informe</a>)

    rewritten, = ContentSeeds::Tokens.to_tokens(html, id_to_key: id_to_key)

    expect(rewritten).to eq(%(<a href=consul-seed://blob/#{blob.key}>Informe</a>))
  end

  it "keeps a filename with an apostrophe together with its disposition" do
    filename = "Pla%20de%20l'Horta%20(1).pdf"
    url = "/rails/active_storage/blobs/redirect/#{blob.signed_id}/#{filename}?disposition=attachment"
    html = %(<a href="#{url}">x</a>)

    rewritten, = ContentSeeds::Tokens.to_tokens(html, id_to_key: id_to_key)

    expect(rewritten).to eq(%(<a href="consul-seed://blob/#{blob.key}?disposition=attachment">x</a>))
  end
end
