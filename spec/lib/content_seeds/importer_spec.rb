require "rails_helper"
require "content_seeds/importer"

describe ContentSeeds::Importer do
  let(:root) { Rails.root.join("spec/fixtures/content_seeds") }
  let(:editor_key) { "v2fgl91pnwsnimkkvmeef137w21o" }
  let(:document_key) { "e4eaal50v6xdt8litjamnenmjkal" }

  before { create(:administrator) }

  def run_import(overwrite: false)
    ContentSeeds::Importer.call(name: "sample", root: root, overwrite: overwrite)
  end

  it "requires an administrator on the target database" do
    Administrator.delete_all

    expect { run_import }.to raise_error(ContentSeeds::Importer::Error, /no administrator/)
  end

  describe "a first import" do
    let!(:report) { run_import }

    it "creates the blobs with their original keys and uploads the files through the storage service" do
      expect(report.counts["blobs"]).to eq 4

      blob = ActiveStorage::Blob.find_by!(key: editor_key)
      expect(blob.filename.to_s).to eq "clippy.png"
      expect(blob.byte_size).to eq 67983
      expect(blob.metadata).to include("width" => 475, "height" => 475)
      expect(File.exist?(ActiveStorage::Blob.service.path_for(editor_key))).to be true
    end

    it "creates the ckeditor picture attached to the imported blob" do
      picture = Ckeditor::Picture.last

      expect(report.counts["ckeditor_pictures"]).to eq 1
      expect(picture.storage_data.blob.key).to eq editor_key
      expect(picture.data_file_name).to eq "clippy.png"
      expect(picture.width).to eq 475
    end

    it "attaches the site image to its blob" do
      image = SiteCustomization::Image.find_by!(name: "logo_header")

      expect(image.image.blob.key).to eq "vpw5ynbpkgjomwwqgiebq3q3l9rn"
    end

    it "creates the admin document owned by the administrator" do
      document = Document.admin.find_by!(title: "Imported document")

      expect(document.attachment.blob.key).to eq document_key
      expect(document.user).to eq Administrator.first.user
      expect(document.documentable).to be(nil)
    end

    it "creates the page with every translation" do
      page = SiteCustomization::Page.find_by!(slug: "imported-page")

      expect(page.status).to eq "published"
      expect(Globalize.with_locale(:en) { page.title }).to eq "Imported page"
      expect(Globalize.with_locale(:es) { page.title }).to eq "Página importada"
    end

    it "rewrites editor tokens into paths signed by this application" do
      page = SiteCustomization::Page.find_by!(slug: "imported-page")
      content = Globalize.with_locale(:en) { page.content }
      blob = ActiveStorage::Blob.find_by!(key: editor_key)

      representation = content[%r{/rails/active_storage/representations/redirect/[^"]+}]
      expect(representation).to be_present
      signed_id, signed_variation = representation.split("/")[5, 2]
      expect(ActiveStorage::Blob.find_signed!(signed_id)).to eq blob
      expect(ActiveStorage::Variation.decode(signed_variation).transformations)
        .to eq(format: "png", resize: "800>")

      download = content[%r{/rails/active_storage/blobs/redirect/[^"]+}]
      expect(download).to end_with("/empty.pdf?disposition=attachment")
      expect(ActiveStorage::Blob.find_signed!(download.split("/")[5]).key).to eq document_key

      expect(content).not_to include("consul-seed://")
      expect(report.unresolved_tokens).to be_empty
    end

    it "upserts the content block for an enabled locale and reports the one for a locale that is not" do
      expect(SiteCustomization::ContentBlock.find_by(name: "footer",
                                                     locale: "en").body).to eq "<p>Footer body</p>"
      expect(SiteCustomization::ContentBlock.where(locale: "xx")).to be_empty

      skipped = report.skipped.find { |s| s.dataset == "content_blocks" }
      expect(skipped.natural_key).to eq "footer / xx"
      expect(skipped.message).to include("not enabled")
    end

    it "writes every translation of the i18n content" do
      content = I18nContent.find_by!(key: "imported.section.title")

      expect(Globalize.with_locale(:en) { content.value }).to eq "Imported English value"
      expect(Globalize.with_locale(:es) { content.value }).to eq "Valor importado en español"
    end

    it "creates the header card with its translations and image" do
      card = Widget::Card.find_by!(header: true, link_url: "/imported")

      expect(Globalize.with_locale(:es) { card.title }).to eq "Tarjeta importada"
      expect(card.cardable).to be(nil)
      expect(card.image.title).to eq "Imported card image"
      expect(card.image.attachment.blob.key).to eq "9i3orjwsnlfwc6f4aq1gersqpoev"
      expect(Globalize.with_locale(:en) do
        card.description
      end).to include("/rails/active_storage/blobs/redirect/")
    end

    it "reports a budget extension whose budget does not exist instead of failing" do
      expect(Budget::Extension.count).to eq 0

      skipped = report.skipped.find { |s| s.dataset == "budget_extensions" }
      expect(skipped.natural_key).to eq "nonexistent-budget / Nonexistent Budget"
      expect(skipped.message).to eq "budget not found on target"
    end

    it "is idempotent: a second run reuses the blobs and creates nothing" do
      counts = lambda do
        [ActiveStorage::Blob.count, Ckeditor::Picture.count, Document.count, SiteCustomization::Page.count,
         Widget::Card.count, Image.count, I18nContent.count, SiteCustomization::ContentBlock.count]
      end
      before_counts = counts.call

      second = run_import

      expect(counts.call).to eq before_counts
      expect(second.counts).to include("blobs_reused" => 4, "pages_skipped" => 1, "cards_skipped" => 1,
                                       "documents_skipped" => 1, "ckeditor_pictures_skipped" => 1)
      expect(second.counts.keys).not_to include("blobs", "pages", "cards", "documents")
    end

    it "updates existing entity records only when overwriting" do
      page = SiteCustomization::Page.find_by!(slug: "imported-page")
      Globalize.with_locale(:en) { page.update!(title: "Edited on the target") }

      run_import
      expect(Globalize.with_locale(:en) { page.reload.title }).to eq "Edited on the target"

      overwritten = run_import(overwrite: true)
      expect(Globalize.with_locale(:en) { page.reload.title }).to eq "Imported page"
      expect(overwritten.counts).to include("pages_updated" => 1)
      expect(SiteCustomization::Page.where(slug: "imported-page").count).to eq 1
    end
  end

  describe "#run (one step at a time)" do
    it "runs only the requested step, in the documented order" do
      expect(ContentSeeds::Importer::STEPS).to eq %w[blobs ckeditor_pictures site_images documents pages
                                                     content_blocks i18n_contents cards budget_extensions]

      blobs = ContentSeeds::Importer.new(name: "sample", root: root).run("blobs")
      expect(blobs.counts).to eq("blobs" => 4)
      expect(SiteCustomization::Image.find_by(name: "logo_header")).to be(nil)

      images = ContentSeeds::Importer.new(name: "sample", root: root).run("site_images")
      expect(images.counts).to eq("site_images" => 1)
      logo = SiteCustomization::Image.find_by!(name: "logo_header")
      expect(logo.image.blob.key).to eq "vpw5ynbpkgjomwwqgiebq3q3l9rn"
    end

    it "fails clearly when a step needs a blob that an earlier step has not imported yet" do
      expect { ContentSeeds::Importer.new(name: "sample", root: root).run("site_images") }
        .to raise_error(ContentSeeds::Importer::ImportFailed) { |error|
          expect(error.report.failures.first.message).to include("was not imported")
        }
    end

    it "rejects an unknown step" do
      expect { ContentSeeds::Importer.new(name: "sample", root: root).run("users") }
        .to raise_error(ArgumentError, /unknown import step/)
    end
  end

  it "links the budget extension when the budget exists on the target" do
    budget = create(:budget, name: "Nonexistent Budget")

    report = run_import

    extension = Budget::Extension.find_by!(budget: budget)
    expect(report.counts["budget_extensions"]).to eq 1
    expect(extension.stats_override).to be true
    expect(Globalize.with_locale(:es) do
      extension.stats_override_content
    end).to eq "<p>Contenido de estadísticas</p>"
    expect(report.skipped.map(&:dataset)).not_to include("budget_extensions")
  end

  it "records failures per record, keeps going and raises ImportFailed at the end" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "broken", "files"))
      File.write(File.join(dir, "broken", "content.yml"), {
        "meta" => { "default_locale" => "en", "locales" => ["en"] },
        "blobs" => [{ "key" => "missingfilekey00000000000000",
                      "filename" => "x.png",
                      "content_type" => "image/png",
                      "byte_size" => 1 }],
        "ckeditor_pictures" => [],
        "site_images" => [],
        "documents" => [],
        "pages" => [{ "slug" => "still-imported",
                      "status" => "draft",
                      "translations" => { "en" => { "title" => "Still imported",
                                                    "content" => "<p>ok</p>" }}}],
        "content_blocks" => [],
        "i18n_contents" => [],
        "cards" => [],
        "budget_extensions" => []
      }.to_yaml)

      expect do
        ContentSeeds::Importer.call(name: "broken", root: dir)
      end.to raise_error(ContentSeeds::Importer::ImportFailed) { |error|
        expect(error.report.failures.map(&:natural_key)).to eq ["missingfilekey00000000000000"]
        expect(error.report.failures.first.message).to include("missing file")
        expect(error.report.counts["pages"]).to eq 1
      }

      expect(SiteCustomization::Page.find_by(slug: "still-imported")).to be_present
    end
  end
end

describe ContentSeeds::Importer, "natural keys and safety nets" do
  let(:sample_files) { Rails.root.join("spec/fixtures/content_seeds/sample/files") }
  let(:jpeg_key) { "9i3orjwsnlfwc6f4aq1gersqpoev" }
  let(:pdf_key) { "e4eaal50v6xdt8litjamnenmjkal" }

  before { create(:administrator) }

  def base_bundle
    {
      "meta" => { "default_locale" => "es", "locales" => %w[es en] },
      "blobs" => [],
      "ckeditor_pictures" => [],
      "site_images" => [],
      "documents" => [],
      "pages" => [],
      "content_blocks" => [],
      "i18n_contents" => [],
      "cards" => [],
      "budget_extensions" => []
    }
  end

  def blob_row(key, filename, content_type)
    { "key" => key,
      "filename" => filename,
      "content_type" => content_type,
      "byte_size" => File.size(sample_files.join(key)) }
  end

  def card_row(title, cardable: nil, header: false, link_url: "/x")
    { "header" => header,
      "columns" => 4,
      "order" => 1,
      "link_url" => link_url,
      "cardable" => cardable,
      "image" => nil,
      "translations" => { "es" => { "title" => title }}}
  end

  def import(bundle, overwrite: false)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "b", "files"))
      bundle["blobs"].each do |b|
        FileUtils.cp(sample_files.join(b["key"]), File.join(dir, "b", "files", b["key"]))
      end
      File.write(File.join(dir, "b", "content.yml"), bundle.to_yaml)
      begin
        ContentSeeds::Importer.call(name: "b", root: dir, overwrite: overwrite)
      rescue ContentSeeds::Importer::ImportFailed => e
        e.report
      end
    end
  end

  it "treats the homepage header as a singleton: the existing header is updated, never duplicated" do
    old_header = create(:widget_card, header: true)
    Globalize.with_locale(:es) { old_header.update!(title: "Cabecera antigua") }

    first = import(base_bundle.merge("cards" => [card_row("Cabecera importada", header: true,
                                                                                link_url: "/budgets")]))
    expect(first.counts).to include("cards_skipped" => 1)
    expect(Widget::Card.header.count).to eq 1

    import(
base_bundle.merge("cards" => [card_row("Cabecera importada", header: true,
                                                             link_url: "/budgets")]), overwrite: true
)
    expect(Widget::Card.header.count).to eq 1
    expect(Globalize.with_locale(:es) { Widget::Card.header.first.title }).to eq "Cabecera importada"
  end

  it "keys cards by their owner page, so identical cards on two pages stay two cards" do
    page_a = create(:site_customization_page, slug: "page-a")
    page_b = create(:site_customization_page, slug: "page-b")
    cards = [
      card_row("Misma tarjeta", cardable: { "type" => "SiteCustomization::Page", "slug" => "page-a" }),
      card_row("Misma tarjeta", cardable: { "type" => "SiteCustomization::Page", "slug" => "page-b" })
    ]

    import(base_bundle.merge("cards" => cards))
    second = import(base_bundle.merge("cards" => cards), overwrite: true)

    expect(page_a.cards.count).to eq 1
    expect(page_b.cards.count).to eq 1
    expect(second.counts).to include("cards_updated" => 2)
  end

  it "recognises on re-run a card that has no default-locale title" do
    row = card_row("Only English").merge("translations" => { "en" => { "title" => "Only English" }})

    import(base_bundle.merge("cards" => [row]))
    second = import(base_bundle.merge("cards" => [row]))

    expect(Widget::Card.body.count).to eq 1
    expect(second.counts).to include("cards_skipped" => 1)
  end

  it "refuses a card with an unsupported cardable type instead of turning it into a homepage card" do
    report = import(base_bundle.merge("cards" => [card_row("SDG", cardable: { "type" => "SDG::Phase" })]))

    expect(Widget::Card.count).to eq 0
    expect(report.failures.map(&:message).join).to include("unsupported cardable type")
  end

  it "fails loudly when an imported blob ends up attached to nothing" do
    report = import(base_bundle.merge("blobs" => [blob_row(pdf_key, "empty.pdf", "application/pdf")]))

    failure = report.failures.find { |f| f.dataset == "blobs" }
    expect(failure.natural_key).to eq pdf_key
    expect(failure.message).to include("attached to no record")
  end

  it "keys documents by blob: a same-titled document with another file is imported and its blob attached" do
    admin = Administrator.first.user
    existing = Document.new(title: "Informe", user: admin, admin: true, documentable: nil)
    existing.attachment.attach(io: File.open(Rails.root.join("spec/fixtures/files/empty.pdf")),
                               filename: "empty.pdf", content_type: "application/pdf")
    existing.save!

    report = import(base_bundle.merge("blobs" => [blob_row(pdf_key, "empty.pdf", "application/pdf")],
                                      "documents" => [{ "title" => "Informe", "blob_key" => pdf_key }]))

    expect(report.failures).to be_empty
    expect(Document.admin.where(title: "Informe").count).to eq 2
    expect(ActiveStorage::Blob.find_by!(key: pdf_key).attachments.count).to eq 1
  end

  it "does not let Document#remove_metadata rewrite the imported file" do
    path = ActiveStorage::Blob.service.path_for(pdf_key)
    FileUtils.rm_f("#{path}_original") # left behind by runs before this safeguard existed

    import(base_bundle.merge("blobs" => [blob_row(pdf_key, "empty.pdf", "application/pdf")],
                             "documents" => [{ "title" => "Informe", "blob_key" => pdf_key }]))

    expect(File.size(path)).to eq File.size(sample_files.join(pdf_key))
    expect(File.exist?("#{path}_original")).to be false
    expect(Document.__callbacks[:save].map(&:filter)).to include(:remove_metadata)
  end

  it "keeps html out of the report for skipped budget extensions and content blocks" do
    img = %(<img src="consul-seed://blob/#{jpeg_key}">)
    bundle = base_bundle.merge(
      "blobs" => [blob_row(jpeg_key, "clippy.jpg", "image/jpeg")],
      "ckeditor_pictures" => [{ "blob_key" => jpeg_key, "width" => 1, "height" => 1 }],
      "content_blocks" => [{ "name" => "footer", "locale" => "xx", "body" => img }],
      "budget_extensions" => [{ "budget" => { "slug" => "nope", "name" => "Nope" },
                                "stats_override" => true,
                                "results_extension" => false,
                                "translations" => { "es" => { "stats_override_content" => img,
                                                              "results_extension_content" => nil }}}]
    )

    report = import(bundle)

    expect(report.skipped.map(&:natural_key)).to contain_exactly("footer / xx", "nope / Nope")
    expect(report.skipped.map(&:message).join).not_to include("<img", "consul-seed://")
  end
end
