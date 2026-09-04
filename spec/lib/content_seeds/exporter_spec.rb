require "rails_helper"
require "content_seeds/sql"
require "content_seeds/remote"
require "content_seeds/exporter"

def run_sql(sql)
  JSON.parse(ActiveRecord::Base.connection.select_value(sql))
end

describe ContentSeeds::SQL do
  let(:since) { Date.parse("2026-06-01") }

  describe ".pages" do
    it "includes a page created before the window when a translation was added inside it" do
      page = travel_to(since - 10.days) { create(:site_customization_page, slug: "old-page") }
      travel_to(since + 5.days) do
        Globalize.with_locale(:ca) do
          page.update!(title: "Titol", content: "Text")
        end
      end

      rows = run_sql(ContentSeeds::SQL.pages(since: since))
      row = rows.find { |r| r["slug"] == "old-page" }

      expect(row).to be_present
      expect(row["translations"].keys).to contain_exactly("en", "ca")
    end

    it "includes a page created before the window when one of its translations was edited inside it" do
      page = travel_to(since - 10.days) { create(:site_customization_page, slug: "edited-page") }
      travel_to(since + 5.days) { page.update!(content: "Edited") }

      rows = run_sql(ContentSeeds::SQL.pages(since: since))

      expect(rows.map { |r| r["slug"] }).to include("edited-page")
    end

    it "excludes a page untouched since before the window" do
      travel_to(since - 10.days) { create(:site_customization_page, slug: "untouched-page") }

      rows = run_sql(ContentSeeds::SQL.pages(since: since))

      expect(rows.map { |r| r["slug"] }).not_to include("untouched-page")
    end

    it "includes a page created inside the window with its attributes and translation" do
      page = travel_to(since + 1.day) { create(:site_customization_page, slug: "new-page") }

      row = run_sql(ContentSeeds::SQL.pages(since: since)).find { |r| r["slug"] == "new-page" }

      expect(row).to include("status" => "draft", "more_info_flag" => false, "print_content_flag" => false)
      expect(row["translations"]["en"]).to include("title" => page.title, "content" => page.content)
    end
  end

  describe ".documents" do
    def build_document(user:, title:, admin:)
      document = Document.new(title: title, user: user, admin: admin, documentable: nil)
      document.attachment.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/empty.pdf")),
        filename: "empty.pdf", content_type: "application/pdf"
      )
      document.save!
      document
    end

    it "includes only admin documents without a documentable, created or modified inside the window" do
      user = create(:user)
      admin_doc = travel_to(since + 1.day) { build_document(user: user, title: "Admin doc", admin: true) }
      travel_to(since - 1.day) { build_document(user: user, title: "Old admin doc", admin: true) }
      travel_to(since + 1.day) { build_document(user: user, title: "Non admin doc", admin: false) }

      rows = run_sql(ContentSeeds::SQL.documents(since: since))

      expect(rows.map { |r| r["title"] }).to contain_exactly("Admin doc")
      expect(rows.first["blob_key"]).to eq(admin_doc.attachment.blob.key)
    end
  end

  describe ".site_images" do
    it "includes a site image whose blob was created inside the window" do
      image = travel_to(since + 1.day) { create(:site_customization_image, name: "logo_header") }

      rows = run_sql(ContentSeeds::SQL.site_images(since: since))

      expect(rows).to contain_exactly("name" => "logo_header", "blob_key" => image.image.blob.key)
    end

    it "excludes a site image whose blob predates the window" do
      travel_to(since - 1.day) { create(:site_customization_image, name: "logo_header") }

      expect(run_sql(ContentSeeds::SQL.site_images(since: since))).to be_empty
    end
  end

  describe ".content_blocks" do
    it "includes a content block updated inside the window" do
      block = travel_to(since - 10.days) do
        create(:site_customization_content_block, name: "footer", locale: "en")
      end
      travel_to(since + 1.day) { block.update!(body: "New body") }
      travel_to(since - 10.days) do
        create(:site_customization_content_block, name: "top_links", locale: "en")
      end

      rows = run_sql(ContentSeeds::SQL.content_blocks(since: since))

      expect(rows.map { |r| r["name"] }).to contain_exactly("footer")
      expect(rows.first["body"]).to eq("New body")
    end
  end

  describe ".i18n_contents" do
    it "includes a content whose translation was updated inside the window, with every locale" do
      content = travel_to(since - 10.days) { create(:i18n_content, key: "some.key") }
      travel_to(since + 1.day) { Globalize.with_locale(:en) { content.update!(value: "Updated") } }
      travel_to(since - 10.days) { create(:i18n_content, key: "other.key") }

      rows = run_sql(ContentSeeds::SQL.i18n_contents(since: since))

      expect(rows.map { |r| r["key"] }).to contain_exactly("some.key")
      expect(rows.first["translations"]).to include("en" => "Updated")
    end
  end

  describe ".cards" do
    it "represents cardable as null when there is none" do
      card = travel_to(since + 1.day) { create(:widget_card) }

      row = run_sql(ContentSeeds::SQL.cards(since: since)).find { |r| r["link_url"] == card.link_url }

      expect(row["cardable"]).to be(nil)
      expect(row["image"]).to eq("blob_key" => card.image.attachment.blob.key, "title" => card.image.title)
      expect(row["translations"]["en"]).to include("title" => card.title)
    end

    it "represents a SiteCustomization::Page cardable by slug" do
      page = create(:site_customization_page, slug: "info")
      card = travel_to(since + 1.day) { create(:widget_card, cardable: page) }

      row = run_sql(ContentSeeds::SQL.cards(since: since)).find { |r| r["link_url"] == card.link_url }

      expect(row["cardable"]).to eq("type" => "SiteCustomization::Page", "slug" => "info")
    end

    it "represents a WebSection cardable by name" do
      section = create(:web_section, name: "homepage")
      card = travel_to(since + 1.day) { create(:widget_card, cardable: section) }

      row = run_sql(ContentSeeds::SQL.cards(since: since)).find { |r| r["link_url"] == card.link_url }

      expect(row["cardable"]).to eq("type" => "WebSection", "name" => "homepage")
    end

    it "excludes a card untouched since before the window" do
      travel_to(since - 10.days) { create(:widget_card) }

      expect(run_sql(ContentSeeds::SQL.cards(since: since))).to be_empty
    end
  end

  describe ".budget_extensions" do
    it "resolves the budget's name in the given default locale" do
      budget = create(:budget)
      extension = travel_to(since + 1.day) do
        ext = Budget::Extension.create!(budget: budget, stats_override: true)
        Globalize.with_locale(:en) { ext.update!(stats_override_content: "Stats") }
        ext
      end

      row = run_sql(ContentSeeds::SQL.budget_extensions(since: since, default_locale: "en")).first

      expect(row["budget"]).to eq("slug" => extension.budget.slug, "name" => budget.name)
      expect(row["stats_override"]).to be(true)
      expect(row["translations"]["en"]).to include("stats_override_content" => "Stats")
    end

    it "falls back to the first translation's name when the default locale has none" do
      budget = create(:budget)
      Globalize.with_locale(:ca) { budget.update!(name: "Pressupost") }
      travel_to(since + 1.day) { Budget::Extension.create!(budget: budget) }

      row = run_sql(ContentSeeds::SQL.budget_extensions(since: since, default_locale: "nolocale")).first

      expect(row["budget"]["name"]).to eq("Pressupost")
    end

    it "excludes a budget extension untouched since before the window" do
      budget = create(:budget)
      travel_to(since - 10.days) { Budget::Extension.create!(budget: budget) }

      expect(run_sql(ContentSeeds::SQL.budget_extensions(since: since, default_locale: "en"))).to be_empty
    end
  end

  describe ".ckeditor_pictures and .ckeditor_pictures_for_blob_ids" do
    def create_picture(filename: "clippy.png")
      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(Rails.root.join("spec/fixtures/files/#{filename}")),
        filename: filename, content_type: "image/png"
      )
      picture = Ckeditor::Picture.new(width: 475, height: 475, data: blob)
      picture.save!
      picture
    end

    it "includes ckeditor pictures created or modified inside the window" do
      inside = travel_to(since + 1.day) { create_picture }
      travel_to(since - 10.days) { create_picture }

      rows = run_sql(ContentSeeds::SQL.ckeditor_pictures(since: since))

      expect(rows.map { |r| r["blob_key"] }).to contain_exactly(inside.storage_data.blob.key)
    end

    it "fetches pictures referenced from html by blob id, regardless of when they were created" do
      old_picture = travel_to(since - 10.days) { create_picture }

      rows = run_sql(ContentSeeds::SQL.ckeditor_pictures_for_blob_ids([old_picture.storage_data.blob.id]))

      expect(rows.map { |r| r["blob_key"] }).to contain_exactly(old_picture.storage_data.blob.key)
    end

    it "returns an empty array without querying when given no ids" do
      expect(run_sql(ContentSeeds::SQL.ckeditor_pictures_for_blob_ids([]))).to eq([])
    end
  end

  describe ".blobs_by_ids and .blobs_by_keys" do
    let(:blob) do
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "a.png",
                                             content_type: "image/png")
    end

    it "returns only the requested blobs, by id" do
      other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "b.png",
                                                     content_type: "image/png")

      rows = run_sql(ContentSeeds::SQL.blobs_by_ids([blob.id]))

      expect(rows.map { |r| r["key"] }).to contain_exactly(blob.key)
      expect(rows.first).to include(
        "id" => blob.id, "filename" => "a.png", "content_type" => "image/png", "byte_size" => 5
      )
      other.purge
    end

    it "returns only the requested blobs, by key" do
      rows = run_sql(ContentSeeds::SQL.blobs_by_keys([blob.key]))

      expect(rows.map { |r| r["key"] }).to contain_exactly(blob.key)
    end

    it "raises rather than interpolate an invalid id" do
      expect { ContentSeeds::SQL.blobs_by_ids(["1; DROP TABLE users"]) }.to raise_error(ArgumentError)
    end

    it "raises rather than interpolate an invalid key" do
      expect { ContentSeeds::SQL.blobs_by_keys(["not valid'; --"]) }.to raise_error(ArgumentError)
    end
  end

  describe ".bundle" do
    it "composes every since-windowed dataset into one json object" do
      travel_to(since + 1.day) { create(:site_customization_page, slug: "bundled-page") }

      row = run_sql(ContentSeeds::SQL.bundle(since: since, default_locale: "en"))

      expect(row.keys).to contain_exactly(
        "pages", "documents", "site_images", "content_blocks",
        "i18n_contents", "cards", "budget_extensions", "ckeditor_pictures"
      )
      expect(row["pages"].map { |p| p["slug"] }).to include("bundled-page")
    end
  end

  describe ".normalize_since" do
    it "accepts a Date and returns an ISO date string" do
      expect(ContentSeeds::SQL.normalize_since(Date.parse("2026-06-01"))).to eq("2026-06-01")
    end

    it "rejects anything that isn't a plain ISO date" do
      expect do
        ContentSeeds::SQL.normalize_since("2026-06-01; DROP TABLE users;--")
      end.to raise_error(ArgumentError)
    end
  end
end

describe ContentSeeds::Remote do
  describe "#query" do
    it "runs ssh and psql as separate argv elements, without a local shell, passing the password on stdin" do
      remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
      allow(remote).to receive(:database_config).and_return(
        host: "192.0.2.10", port: 5432, database: "consul_db",
        username: "consul", password: "s3cret pass"
      )
      allow(Open3).to receive(:capture3).and_return(["[]", "",
                                                     instance_double(Process::Status, success?: true)])

      remote.query("SELECT 1")

      expect(Open3).to have_received(:capture3) do |*argv, stdin_data:|
        expect(argv[0]).to eq("ssh")
        expect(argv).to include("-o", "BatchMode=yes", "preprod")
        expect(argv.last).to start_with("IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql ")
        expect(argv.last).not_to include("s3cret")
        remote_command = Shellwords.split(argv.last.sub(/\A.*exec /, ""))
        expect(remote_command).to include("-h", "192.0.2.10", "-U", "consul", "-d", "consul_db")
        expect(stdin_data.lines.first).to eq("s3cret pass\n")
        expect(stdin_data.lines[1]).to start_with("SET default_transaction_read_only = on;")
        expect(stdin_data).to include("SELECT 1")
      end
    end

    it "inserts SSH_OPTS before the host so a ControlMaster socket can be reused" do
      remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current",
                                        ssh_opts: "-o ControlPath=~/.ssh/cm-%h")
      allow(remote).to receive(:database_config).and_return(
        host: "db", port: 5432, database: "d", username: "u", password: "p"
      )
      allow(Open3).to receive(:capture3).and_return(["[]", "",
                                                     instance_double(Process::Status, success?: true)])

      remote.query("SELECT 1")

      expect(Open3).to have_received(:capture3) do |*argv, **_kwargs|
        host_index = argv.index("preprod")
        expect(argv[host_index - 2, 2]).to eq(["-o", "ControlPath=~/.ssh/cm-%h"])
      end
    end
  end

  describe "#fetch_files" do
    it "lists files using the <key[0..1]>/<key[2..3]>/<key> layout and honours SSH_OPTS" do
      remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current",
                                        ssh_opts: "-o ControlPath=~/.ssh/cm-%h")
      allow(Open3).to receive(:capture3).and_return(["", "",
                                                     instance_double(Process::Status, success?: true)])
      into = Dir.mktmpdir

      written_list = nil
      allow(File).to receive(:write).and_wrap_original do |original, path, content|
        written_list = content if path.to_s.end_with?("/files")
        original.call(path, content)
      end

      remote.fetch_files(["abcdefghijklmnopqrstuvwxyz01"], into: into)

      expect(written_list).to eq("ab/cd/abcdefghijklmnopqrstuvwxyz01")
      expect(Open3).to have_received(:capture3) do |*argv|
        expect(argv[0]).to eq("rsync")
        expect(argv).to include("-e")
        ssh_flag = Shellwords.split(argv[argv.index("-e") + 1])
        expect(ssh_flag).to eq(["ssh", "-o", "BatchMode=yes", "-o", "ControlPath=~/.ssh/cm-%h"])
        expect(argv.last).to eq("#{into}/")
        expect(argv[-2]).to eq("preprod:/var/consul/current/storage/")
      end
    ensure
      FileUtils.remove_entry(into) if into
    end

    it "does not call rsync when there are no keys" do
      remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
      allow(Open3).to receive(:capture3)

      remote.fetch_files([], into: Dir.mktmpdir)

      expect(Open3).not_to have_received(:capture3)
    end
  end

  describe "#app_dir" do
    it "prefers /var/consul/current when it exists" do
      remote = ContentSeeds::Remote.new(host: "preprod")
      allow(Open3).to receive(:capture3).and_return(["/var/consul/current\n", "",
                                                     instance_double(Process::Status, success?: true)])

      expect(remote.app_dir).to eq("/var/consul/current")
    end

    it "falls back to the single /var/www/*/current match" do
      remote = ContentSeeds::Remote.new(host: "preprod")
      call_count = 0
      allow(Open3).to receive(:capture3) do |*_argv|
        call_count += 1
        stdout = call_count == 1 ? "" : "/var/www/app/current\n"
        [stdout, "", instance_double(Process::Status, success?: true)]
      end

      expect(remote.app_dir).to eq("/var/www/app/current")
    end

    it "raises when neither candidate resolves to exactly one directory" do
      remote = ContentSeeds::Remote.new(host: "preprod")
      allow(Open3).to receive(:capture3).and_return(["", "",
                                                     instance_double(Process::Status, success?: true)])

      expect { remote.app_dir }.to raise_error(ContentSeeds::Remote::Error, /APP_DIR/)
    end
  end

  describe "#database_config" do
    it "reads the DB_ENV section (default production) and resolves << merge keys" do
      yaml = <<~YAML
        default: &default
          adapter: postgresql
          host: 192.0.2.10
          username: consul
          password: secret
        preproduction:
          <<: *default
          database: consul_db
      YAML
      remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
      allow(Open3).to receive(:capture3).and_return([yaml, "",
                                                     instance_double(Process::Status, success?: true)])

      with_env("DB_ENV" => "preproduction") do
        config = remote.database_config

        expect(config).to eq(host: "192.0.2.10", port: nil, database: "consul_db",
                             username: "consul", password: "secret")
      end
    end

    it "applies SEED_DB_* overrides on top of whatever database.yml says" do
      yaml = <<~YAML
        production:
          host: internal-db
          database: consul
          username: consul
          password: secret
      YAML
      remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
      allow(Open3).to receive(:capture3).and_return([yaml, "",
                                                     instance_double(Process::Status, success?: true)])

      with_env("SEED_DB_HOST" => "127.0.0.1", "SEED_DB_PASSWORD" => "overridden") do
        config = remote.database_config

        expect(config[:host]).to eq("127.0.0.1")
        expect(config[:password]).to eq("overridden")
        expect(config[:database]).to eq("consul")
      end
    end
  end
end

def with_env(overrides)
  original = ENV.to_hash
  overrides.each { |key, value| ENV[key] = value }
  yield
ensure
  ENV.replace(original)
end

describe ContentSeeds::SQL, ".setting_value" do
  it "reads one setting from the settings table" do
    Setting["locales.default"] = "ca"

    sql = ContentSeeds::SQL.setting_value("locales.default")

    expect(ActiveRecord::Base.connection.select_value(sql)).to eq "ca"
  end

  it "returns an empty string for a missing setting and rejects keys with unexpected characters" do
    Setting.where(key: "locales.default").delete_all

    sql = ContentSeeds::SQL.setting_value("locales.default")

    expect(ActiveRecord::Base.connection.select_value(sql)).to eq ""
    expect { ContentSeeds::SQL.setting_value("x'; DROP TABLE settings; --") }.to raise_error(ArgumentError)
  end
end

describe ContentSeeds::Exporter, "files to fetch" do
  it "copies every file by default and only the blobs newer than FILES_SINCE when it is set" do
    exporter = ContentSeeds::Exporter.new(host: "example-host", name: "sample")
    blobs = [
      { "key" => "oldblobkey", "created_at" => "2026-05-01T10:00:00" },
      { "key" => "newblobkey", "created_at" => "2026-07-01T10:00:00" }
    ]

    expect(exporter.send(:keys_to_fetch, blobs)).to eq %w[oldblobkey newblobkey]

    stub_const("ENV", ENV.to_h.merge("FILES_SINCE" => "2026-06-01"))
    exporter = ContentSeeds::Exporter.new(host: "example-host", name: "sample")

    expect(exporter.send(:keys_to_fetch, blobs)).to eq %w[newblobkey]
  end
end

describe ContentSeeds::Exporter, "blob keys" do
  it "includes blobs attached to exported records and blobs only referenced from HTML" do
    exporter = ContentSeeds::Exporter.new(host: "example-host", name: "sample")
    bundle = {
      "documents" => [{ "blob_key" => "docblobkey" }],
      "site_images" => [{ "blob_key" => "logoblobkey" }],
      "ckeditor_pictures" => [{ "blob_key" => "pictureblobkey" }],
      "cards" => [{ "image" => { "blob_key" => "cardblobkey" }}, { "image" => nil }]
    }

    keys = exporter.send(:collect_blob_keys, bundle, { 7 => "pictureblobkey", 9 => "olddocblobkey" })

    expect(keys).to contain_exactly("docblobkey", "logoblobkey", "pictureblobkey", "cardblobkey",
                                    "olddocblobkey")
  end
end

describe ContentSeeds::Remote, "hardening" do
  def stub_status(success:, exitstatus:)
    instance_double(Process::Status, success?: success, exitstatus: exitstatus)
  end

  it "tolerates rsync's partial-transfer exit codes so missing files are reported instead of aborting" do
    remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
    allow(Open3).to receive(:capture3).and_return(["", "some files vanished",
                                                   stub_status(success: false, exitstatus: 23)])
    into = Dir.mktmpdir

    expect { remote.fetch_files(["abcdefghijklmnopqrstuvwxyz01"], into: into) }.not_to raise_error
  ensure
    FileUtils.remove_entry(into) if into
  end

  it "still raises for any other rsync failure" do
    remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
    allow(Open3).to receive(:capture3).and_return(["", "connection refused",
                                                   stub_status(success: false, exitstatus: 255)])
    into = Dir.mktmpdir

    expect { remote.fetch_files(["abcdefghijklmnopqrstuvwxyz01"], into: into) }
      .to raise_error(ContentSeeds::Remote::Error, /connection refused/)
  ensure
    FileUtils.remove_entry(into) if into
  end

  it "percent-decodes the components of a database url" do
    remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
    url = "postgres://de%40ploy:p%40ss%2Fw@dbhost:5433/consul%20pre"
    allow(remote).to receive(:database_yaml_section).and_return("url" => url)

    expect(remote.database_config).to include(host: "dbhost", port: 5433, database: "consul pre",
                                              username: "de@ploy", password: "p@ss/w")
  end

  it "never reads the remote database.yml when SEED_DB_* is complete" do
    remote = ContentSeeds::Remote.new(host: "preprod", app_dir: "/var/consul/current")
    allow(Open3).to receive(:capture3)
    stub_const("ENV", ENV.to_h.merge("SEED_DB_HOST" => "dbhost", "SEED_DB_NAME" => "consul",
                                     "SEED_DB_USER" => "seed_user", "SEED_DB_PASSWORD" => "pw"))

    expect(remote.database_config).to eq(host: "dbhost", port: nil, database: "consul", username: "seed_user",
                                         password: "pw")
    expect(Open3).not_to have_received(:capture3)
  end
end

describe ContentSeeds::SQL, "referenced documents and unknown cardables" do
  it "exports admin documents by blob id regardless of their creation date" do
    user = create(:user)
    document = travel_to(2.years.ago) do
      doc = Document.new(title: "Old linked PDF", user: user, admin: true, documentable: nil)
      doc.attachment.attach(io: File.open(Rails.root.join("spec/fixtures/files/empty.pdf")),
                            filename: "empty.pdf", content_type: "application/pdf")
      doc.save!
      doc
    end

    rows = run_sql(ContentSeeds::SQL.documents_for_blob_ids([document.attachment.blob.id]))

    expect(rows).to eq([{ "title" => "Old linked PDF", "blob_key" => document.attachment.blob.key }])
  end

  it "exports an unknown cardable type explicitly instead of turning the card into a homepage card" do
    card = create(:widget_card, header: false)
    card.update_columns(cardable_type: "SDG::Phase", cardable_id: 42)

    row = run_sql(ContentSeeds::SQL.cards(since: 1.day.ago.to_date)).find do |r|
      r["link_url"] == card.link_url
    end

    expect(row["cardable"]).to eq("type" => "SDG::Phase")
  end
end
