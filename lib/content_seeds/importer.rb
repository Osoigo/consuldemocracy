require "content_seeds/tokens"
require "yaml"

module ContentSeeds
  # Idempotently recreates the records and files described by a
  # `db/content_seeds/<name>/content.yml` bundle on the current database.
  #
  # Import order matters: blobs first (everything else references them by
  # key), ckeditor pictures and site images next (so any editor URL or
  # image reference in the datasets that follow resolves to something that
  # already exists), then documents, pages, content blocks, i18n contents,
  # cards and budget extensions.
  #
  # Every top-level record is created (or, with `OVERWRITE=1`, updated) in
  # its own transaction; a failure is recorded with its natural key and the
  # import continues. Singleton tables (site images, content blocks, i18n
  # contents) are always upserted regardless of `OVERWRITE`.
  class Importer
    class Error < StandardError; end

    # Raised by `call` when the report carries at least one failure, so
    # the rake task can turn it into a non-zero exit without losing the
    # report (still reachable as `error.report`).
    class ImportFailed < StandardError
      attr_reader :report

      def initialize(report)
        @report = report
        super("content seeds import finished with #{report.failures.size} failure(s)")
      end
    end

    Failure = Struct.new(:dataset, :natural_key, :message, keyword_init: true)

    Report = Struct.new(:counts, :failures, :skipped, :unresolved_tokens, keyword_init: true) do
      def success?
        failures.empty?
      end
    end

    # Import steps, in dependency order. Each one is also exposed as its own
    # rake task (`content_seeds:import:<step>`); `content_seeds:import` runs
    # them all and then checks for blobs left unattached.
    STEPS = %w[
      blobs
      ckeditor_pictures
      site_images
      documents
      pages
      content_blocks
      i18n_contents
      cards
      budget_extensions
    ].freeze

    def self.call(name:, root: nil, overwrite: ENV["OVERWRITE"] == "1")
      new(name: name, root: root, overwrite: overwrite).call
    end

    # `root` is the directory holding the bundles (`db/content_seeds` by
    # default); `overwrite` makes existing entity records be updated
    # instead of skipped (`OVERWRITE=1` from the rake task).
    def initialize(name:, root: nil, overwrite: ENV["OVERWRITE"] == "1")
      @name = name
      @root = Pathname.new(root || Rails.root.join("db", "content_seeds"))
      @bundle = YAML.safe_load_file(bundle_path, permitted_classes: [Symbol], aliases: true)
      @overwrite = overwrite
      @admin_user = Administrator.first&.user
      raise Error, "cannot import: no administrator found on the target database" if @admin_user.nil?

      @report = Report.new(counts: Hash.new(0), failures: [], skipped: [], unresolved_tokens: [])
      @created_blob_keys = []
    end

    # Runs every step in order, then the unattached-blob safety net.
    def call
      STEPS.each { |step| import_step(step) }
      report_unattached_blobs!
      finish
    end

    # Runs a single step (see STEPS). Earlier steps are expected to have run
    # already: a later step that needs a blob not yet imported fails with a
    # clear "blob <key> was not imported" message instead of guessing.
    def run(step)
      import_step(step)
      finish
    end

    private

      def import_step(step)
        unless STEPS.include?(step.to_s)
          raise ArgumentError, "unknown import step #{step.inspect}; expected one of: #{STEPS.join(", ")}"
        end

        send("import_#{step}!")
      end

      def finish
        raise ImportFailed, report if report.failures.any?

        report
      end

      attr_reader :name, :root, :bundle, :overwrite, :admin_user, :report, :created_blob_keys

      def bundle_path
        root.join(name, "content.yml")
      end

      def files_dir
        root.join(name, "files")
      end

      def with_rescue(dataset, natural_key)
        ActiveRecord::Base.transaction(requires_new: true) { yield }
      rescue StandardError => e
        report.failures << Failure.new(dataset: dataset, natural_key: natural_key, message: e.message)
      end

      def blob_for(key)
        return nil if key.nil?

        ActiveStorage::Blob.find_by(key: key)
      end

      def require_blob(key)
        blob_for(key) || raise(Error, "blob #{key} was not imported")
      end

      # Skips whichever translations lack `attribute` (Globalize's
      # `validates_translation` requires presence on the translation
      # class), yielding [locale, attrs] for the rest.
      def each_translation(translations, presence_of:)
        (translations || {}).each do |locale, attrs|
          next if attrs[presence_of].blank?

          yield locale, attrs
        end
      end

      def rewrite_html(html)
        return html if html.nil?

        rewritten, unresolved = Tokens.from_tokens(html)
        report.unresolved_tokens.concat(unresolved)
        rewritten
      end

      # ---- blobs (singleton: reused by key, never duplicated) ----

      def import_blobs!
        bundle["blobs"].each do |row|
          key = row["key"]

          with_rescue("blobs", key) do
            if blob_for(key)
              report.counts["blobs_reused"] += 1
              next
            end

            path = files_dir.join(key)
            raise Error, "missing file for blob #{key}" unless File.exist?(path)

            byte_size = File.size(path)
            if row["byte_size"].present? && byte_size != row["byte_size"]
              raise Error,
                    "byte size mismatch for blob #{key}: expected #{row["byte_size"]}, got #{byte_size}"
            end

            File.open(path) do |io|
              ActiveStorage::Blob.create_and_upload!(
                io: io,
                filename: row["filename"],
                content_type: row["content_type"],
                key: key,
                identify: false,
                metadata: row["metadata"] || {}
              )
            end
            created_blob_keys << key
            report.counts["blobs"] += 1
          end
        end
      end

      # ---- ckeditor pictures (natural key: blob key) ----
      #
      # Keyed by blob key, like the tokens in the HTML: matching by checksum
      # would leave the bundle's blob unattached whenever the target already
      # has the same file under another key, and unattached blobs are purged
      # by `files:remove_old_cached_attachments`.

      def import_ckeditor_pictures!
        bundle["ckeditor_pictures"].each do |row|
          with_rescue("ckeditor_pictures", row["blob_key"]) do
            blob = require_blob(row["blob_key"])
            existing = Ckeditor::Picture.joins(storage_data_attachment: :blob)
                                        .find_by(active_storage_blobs: { key: blob.key })

            if existing
              # Same blob, so there is nothing to overwrite but the
              # dimensions. `update_columns` on purpose:
              # a regular save would re-run the `apply_data` callback, which
              # re-attaches the blob and saves again, recursing forever.
              if overwrite
                existing.update_columns(width: row["width"], height: row["height"])
                report.counts["ckeditor_pictures_updated"] += 1
              else
                report.counts["ckeditor_pictures_skipped"] += 1
              end
              next
            end

            # `data` is a virtual attr_accessor read by the before_validation
            # `apply_data` callback, which attaches it to `storage_data` and
            # fills the denormalised file columns.
            picture = Ckeditor::Picture.new(width: row["width"], height: row["height"])
            picture.data = blob
            picture.save!
            report.counts["ckeditor_pictures"] += 1
          end
        end
      end

      # ---- site images (singleton, natural key: name) ----

      def import_site_images!
        bundle["site_images"].each do |row|
          with_rescue("site_images", row["name"]) do
            blob = require_blob(row["blob_key"])
            image = SiteCustomization::Image.find_or_initialize_by(name: row["name"])
            image.image.attach(blob)
            image.save!
            report.counts["site_images"] += 1
          end
        end
      end

      # ---- documents (natural key: blob key) ----

      def import_documents!
        without_document_metadata_stripping do
          bundle["documents"].each do |row|
            natural_key = "#{row["title"]} / #{row["blob_key"]}"

            with_rescue("documents", natural_key) do
              blob = require_blob(row["blob_key"])

              # The blob IS the natural key (the HTML links point at it), so
              # an existing document has nothing left to overwrite. Skipping
              # is also the only option: `Document` validates `documentable`
              # presence once persisted, which admin documents never satisfy.
              if Document.admin.joins(attachment_attachment: :blob)
                         .exists?(active_storage_blobs: { key: blob.key })
                report.counts["documents_skipped"] += 1
                next
              end

              document = Document.new(title: row["title"], user: admin_user, admin: true, documentable: nil)
              document.attachment.attach(blob)
              document.save!
              report.counts["documents"] += 1
            end
          end
        end
      end

      # `Document#remove_metadata` (before_save) runs exiftool on the stored
      # file. In the admin flow the file is not there yet at that point, so
      # it is a no-op; here the file already exists and exiftool would
      # rewrite it (changing its bytes away from the blob checksum) and
      # leave a `<key>_original` copy behind. Same end result as an admin
      # upload, without touching the files.
      def without_document_metadata_stripping
        Document.skip_callback(:save, :before, :remove_metadata, raise: false)
        yield
      ensure
        Document.set_callback(:save, :before, :remove_metadata)
      end

      # ---- pages (natural key: slug) ----

      def import_pages!
        bundle["pages"].each do |row|
          with_rescue("pages", row["slug"]) do
            existing = SiteCustomization::Page.find_by(slug: row["slug"])

            if existing && !overwrite
              report.counts["pages_skipped"] += 1
              next
            end

            page = existing || SiteCustomization::Page.new(slug: row["slug"])
            page.status = row["status"]
            page.more_info_flag = row["more_info_flag"]
            page.print_content_flag = row["print_content_flag"]
            page.locale = row["locale"]

            each_translation(row["translations"], presence_of: "title") do |locale, attrs|
              Globalize.with_locale(locale) do
                page.title = attrs["title"]
                page.subtitle = attrs["subtitle"]
                page.content = rewrite_html(attrs["content"])
              end
            end

            page.save!
            report.counts[existing ? "pages_updated" : "pages"] += 1
          end
        end
      end

      # ---- content blocks (singleton, natural key: name + locale) ----

      def import_content_blocks!
        bundle["content_blocks"].each do |row|
          natural_key = "#{row["name"]} / #{row["locale"]}"

          unless Setting.enabled_locales.map(&:to_s).include?(row["locale"].to_s)
            report.skipped << Failure.new(
              dataset: "content_blocks", natural_key: natural_key,
              message: "locale #{row["locale"].inspect} is not enabled on the target"
            )
            next
          end

          with_rescue("content_blocks", natural_key) do
            block = SiteCustomization::ContentBlock.find_or_initialize_by(name: row["name"],
                                                                          locale: row["locale"])
            block.body = rewrite_html(row["body"])
            block.save!
            report.counts["content_blocks"] += 1
          end
        end
      end

      # ---- i18n contents (singleton, natural key: key) ----

      def import_i18n_contents!
        bundle["i18n_contents"].each do |row|
          with_rescue("i18n_contents", row["key"]) do
            content = I18nContent.find_or_create_by!(key: row["key"])

            (row["translations"] || {}).each do |locale, value|
              Globalize.with_locale(locale) { content.update!(value: rewrite_html(value)) }
            end

            report.counts["i18n_contents"] += 1
          end
        end
      end

      # ---- cards ----
      #
      # The homepage header is a singleton in the app (`Widget::Card.header`
      # renders the oldest row), so a header card always maps onto the
      # existing header. Other cards are keyed by owner (`cardable`) +
      # link_url + title, the title being compared on the translation rows
      # themselves (a Globalize read would follow fallbacks and never match
      # a card that lacks the default-locale title).

      def import_cards!
        default_locale = bundle["meta"]["default_locale"]

        bundle["cards"].each do |row|
          title_locale, title = key_title(row["translations"], default_locale)
          natural_key = "#{row["header"] ? "header" : "card"} / #{cardable_key(row["cardable"])} / " \
                        "#{row["link_url"]} / #{title}"

          with_rescue("cards", natural_key) do
            cardable = resolve_cardable(row["cardable"])
            existing = find_card(row, cardable, title_locale, title)

            if existing && !overwrite
              report.counts["cards_skipped"] += 1
              next
            end

            card = existing || Widget::Card.new
            card.header = row["header"]
            card.columns = row["columns"]
            card.order = [row["order"].to_i, 1].max
            card.link_url = row["link_url"]
            card.cardable = cardable

            each_translation(row["translations"], presence_of: "title") do |locale, attrs|
              Globalize.with_locale(locale) do
                card.label = attrs["label"]
                card.title = attrs["title"]
                card.description = rewrite_html(attrs["description"])
                card.link_text = attrs["link_text"]
              end
            end

            card.save!
            attach_card_image(card, row["image"])
            report.counts[existing ? "cards_updated" : "cards"] += 1
          end
        end
      end

      def key_title(translations, default_locale)
        translations = translations || {}
        locale = default_locale if translations.dig(default_locale, "title").present?
        locale ||= translations.find { |_, attrs| attrs["title"].present? }&.first
        [locale, locale && translations[locale]["title"]]
      end

      def cardable_key(cardable)
        return "homepage" if cardable.nil?

        "#{cardable["type"]}:#{cardable["slug"] || cardable["name"] || cardable["id"]}"
      end

      def find_card(row, cardable, title_locale, title)
        return Widget::Card.header.first if row["header"]
        return nil if title_locale.nil?

        Widget::Card.where(header: false, link_url: row["link_url"], cardable: cardable)
                    .joins(:translations)
                    .find_by(widget_card_translations: { locale: title_locale, title: title })
      end

      def resolve_cardable(cardable)
        return nil if cardable.nil?

        target =
          case cardable["type"]
          when "SiteCustomization::Page" then SiteCustomization::Page.find_by(slug: cardable["slug"])
          when "WebSection" then WebSection.find_by(name: cardable["name"])
          else raise Error, "unsupported cardable type #{cardable["type"].inspect}; not importing this card"
          end

        target || raise(Error, "cardable #{cardable.inspect} not found on target")
      end

      def attach_card_image(card, image_row)
        return if image_row.nil?

        blob = require_blob(image_row["blob_key"])
        image = card.image || card.build_image(title: image_row["title"], user: admin_user)
        image.title = image_row["title"]
        image.attachment.attach(blob)
        image.save!
      end

      # ---- budget extensions (natural key: budget slug, fallback default-locale name) ----

      def import_budget_extensions!
        bundle["budget_extensions"].each do |row|
          slug = row.dig("budget", "slug")
          name = row.dig("budget", "name")
          natural_key = "#{slug} / #{name}"
          budget = Budget.find_by(slug: slug) || find_budget_by_name(name)

          if budget.nil?
            report.skipped << Failure.new(
              dataset: "budget_extensions", natural_key: natural_key,
              message: "budget not found on target"
            )
            next
          end

          with_rescue("budget_extensions", natural_key) do
            existing = Budget::Extension.find_by(budget: budget)

            if existing && !overwrite
              report.counts["budget_extensions_skipped"] += 1
              next
            end

            extension = existing || Budget::Extension.new(budget: budget)
            extension.stats_override = row["stats_override"]
            extension.results_extension = row["results_extension"]

            (row["translations"] || {}).each do |locale, attrs|
              Globalize.with_locale(locale) do
                extension.stats_override_content = rewrite_html(attrs["stats_override_content"])
                extension.results_extension_content = rewrite_html(attrs["results_extension_content"])
              end
            end

            extension.save!
            report.counts[existing ? "budget_extensions_updated" : "budget_extensions"] += 1
          end
        end
      end

      # A blob created here but attached to nothing would be purged by
      # `files:remove_old_cached_attachments` within a day, breaking every
      # HTML link that was just signed for it. Better to fail loudly.
      def report_unattached_blobs!
        return if created_blob_keys.empty?

        ActiveStorage::Blob.unattached.where(key: created_blob_keys).pluck(:key).each do |key|
          report.failures << Failure.new(
            dataset: "blobs", natural_key: key,
            message: "blob imported but attached to no record; it would be purged by " \
                     "files:remove_old_cached_attachments and its links would break"
          )
        end
      end

      def find_budget_by_name(name)
        return nil if name.blank?

        Budget.joins(:translations).find_by(budget_translations: { name: name })
      end
  end
end
