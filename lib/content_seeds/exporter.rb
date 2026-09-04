require "content_seeds/sql"
require "content_seeds/remote"
require "content_seeds/tokens"
require "yaml"
require "fileutils"
require "time"

module ContentSeeds
  # Orchestrates a full export. Two SQL round trips against the source
  # database (never written to): the first fetches every since-windowed
  # dataset as a single JSON payload; the second, run only once every HTML
  # field from the first has been scanned for editor URLs, resolves the
  # referenced blob ids into keys and fetches ckeditor pictures that exist
  # but weren't touched inside the window. HTML is then rewritten from
  # source-signed URLs into portable `consul-seed://` tokens, and the
  # files themselves are copied over rsync.
  #
  # Writes `db/content_seeds/<name>/content.yml` and
  # `db/content_seeds/<name>/files/<blob key>`.
  class Exporter
    Report = Struct.new(
      :name, :since, :counts, :blobs_copied, :files_skipped, :unresolved_urls, :missing_files,
      keyword_init: true
    )

    def self.call(host:, name:, since: nil)
      new(host: host, name: name, since: since).call
    end

    def initialize(host:, name:, since: nil)
      @host = host
      @name = name
      @since = SQL.normalize_since(since || 3.months.ago.to_date)
      @files_since = ENV["FILES_SINCE"].presence && SQL.normalize_since(ENV["FILES_SINCE"])
      @remote = Remote.new(host: host, app_dir: ENV["APP_DIR"])
    end

    def call
      @default_locale = resolve_default_locale
      bundle = fetch_bundle
      locations = html_field_locations(bundle)
      referenced_ids = locations.flat_map { |container, key| Tokens.referenced_blob_ids(container[key]) }.uniq

      bundle["ckeditor_pictures"] = merge_ckeditor_pictures(bundle["ckeditor_pictures"], referenced_ids)
      bundle["documents"] = merge_documents(bundle["documents"], referenced_ids)

      id_to_key = fetch_id_to_key(referenced_ids)
      unresolved = rewrite_html!(locations, id_to_key)

      all_keys = collect_blob_keys(bundle, id_to_key)
      blobs = fetch_blobs(all_keys)

      write_bundle(bundle, blobs)
      to_fetch = keys_to_fetch(blobs)
      missing = fetch_files(to_fetch)

      Report.new(
        name: name,
        since: since,
        counts: bundle.transform_values(&:size),
        blobs_copied: to_fetch.size - missing.size,
        files_skipped: blobs.size - to_fetch.size,
        unresolved_urls: unresolved,
        missing_files: missing
      )
    end

    private

      attr_reader :host, :name, :since, :files_since, :default_locale, :remote

      def fetch_bundle
        JSON.parse(remote.query(SQL.bundle(since: since, default_locale: default_locale)))
      end

      # The source's own default locale (`locales.default` setting) decides
      # which translation names budgets and cards in the bundle. It cannot
      # come from the local app: the export task runs without the Rails
      # environment, and the two servers may differ anyway.
      def resolve_default_locale
        ENV["DEFAULT_LOCALE"].presence ||
          remote.query(SQL.setting_value("locales.default")).presence ||
          I18n.default_locale.to_s
      end

      def merge_ckeditor_pictures(original, referenced_ids)
        return original if referenced_ids.empty?

        extra = JSON.parse(remote.query(SQL.ckeditor_pictures_for_blob_ids(referenced_ids)))
        (original + extra).uniq { |row| row["blob_key"] }
      end

      # Admin documents linked from exported HTML travel with it even when
      # they were uploaded before the window (see SQL.documents_for_blob_ids).
      def merge_documents(original, referenced_ids)
        return original if referenced_ids.empty?

        extra = JSON.parse(remote.query(SQL.documents_for_blob_ids(referenced_ids)))
        (original + extra).uniq { |row| [row["title"], row["blob_key"]] }
      end

      def fetch_id_to_key(ids)
        return {} if ids.empty?

        rows = JSON.parse(remote.query(SQL.blobs_by_ids(ids)))
        rows.to_h { |row| [row["id"], row["key"]] }
      end

      # Every HTML field that may contain editor URLs, as
      # [container_hash, key] pairs so callers can both read and rewrite
      # them in place without caring about the shape of each dataset.
      def html_field_locations(bundle)
        locations = []

        bundle["pages"].each do |page|
          (page["translations"] || {}).each_value { |t| locations << [t, "content"] }
        end

        bundle["cards"].each do |card|
          (card["translations"] || {}).each_value { |t| locations << [t, "description"] }
        end

        bundle["content_blocks"].each { |block| locations << [block, "body"] }

        bundle["i18n_contents"].each do |content|
          translations = content["translations"] || {}
          translations.each_key { |locale| locations << [translations, locale] }
        end

        bundle["budget_extensions"].each do |extension|
          (extension["translations"] || {}).each_value do |t|
            locations << [t, "stats_override_content"]
            locations << [t, "results_extension_content"]
          end
        end

        locations
      end

      def rewrite_html!(locations, id_to_key)
        unresolved = []

        locations.each do |container, key|
          html, urls = Tokens.to_tokens(container[key], id_to_key: id_to_key)
          container[key] = html
          unresolved.concat(urls)
        end

        unresolved
      end

      # Every blob the bundle needs: the ones attached to exported records
      # plus the ones only referenced from HTML (a document linked from a
      # page but created outside the window, for instance).
      def collect_blob_keys(bundle, id_to_key)
        keys = []
        keys.concat(bundle["documents"].map { |d| d["blob_key"] })
        keys.concat(bundle["site_images"].map { |i| i["blob_key"] })
        keys.concat(bundle["ckeditor_pictures"].map { |p| p["blob_key"] })
        keys.concat(bundle["cards"].filter_map { |c| c["image"] && c["image"]["blob_key"] })
        keys.concat(id_to_key.values)
        keys.compact.uniq
      end

      def fetch_blobs(keys)
        return [] if keys.empty?

        JSON.parse(remote.query(SQL.blobs_by_keys(keys))).map do |row|
          row.except("id").merge("metadata" => row["metadata"].present? ? JSON.parse(row["metadata"]) : {})
        end
      end

      def collect_locales(bundle)
        locales = []
        %w[pages cards i18n_contents budget_extensions].each do |dataset|
          bundle[dataset].each { |row| locales.concat((row["translations"] || {}).keys) }
        end
        locales.concat(bundle["content_blocks"].map { |b| b["locale"] })
        (locales.compact.uniq << default_locale).uniq.sort
      end

      def write_bundle(bundle, blobs)
        content = {
          "meta" => {
            "exported_at" => Time.now.utc.iso8601,
            "source_env" => ENV["DB_ENV"].presence || "production",
            "since" => since,
            "default_locale" => default_locale,
            "locales" => collect_locales(bundle)
          },
          "blobs" => blobs,
          "ckeditor_pictures" => bundle["ckeditor_pictures"],
          "site_images" => bundle["site_images"],
          "documents" => bundle["documents"],
          "pages" => bundle["pages"],
          "content_blocks" => bundle["content_blocks"],
          "i18n_contents" => bundle["i18n_contents"],
          "cards" => bundle["cards"],
          "budget_extensions" => bundle["budget_extensions"]
        }

        FileUtils.mkdir_p(bundle_dir)
        File.write(bundle_dir.join("content.yml"), YAML.dump(content))
      end

      # Blobs are immutable (a replaced file is a new blob with a new key),
      # so a blob created before `FILES_SINCE` already exists, byte for byte,
      # on a target that is a copy of the source taken on that date. Its row
      # still goes into content.yml (the importer reuses it by key) but its
      # file is not copied into the bundle. Without `FILES_SINCE` every file
      # is copied, which is what an empty target needs.
      def keys_to_fetch(blobs)
        return blobs.map { |b| b["key"] } if files_since.nil?

        # Both sides are ISO-8601 (`YYYY-MM-DD...`) as psql emitted them, so
        # comparing the date part as text is exact and needs no time zone.
        blobs.select { |b| b["created_at"].nil? || b["created_at"][0, 10] >= files_since }
             .map { |b| b["key"] }
      end

      def fetch_files(keys)
        storage_dir = ENV["STORAGE_DIR"].presence || "#{remote.app_dir}/storage"
        files_dir = bundle_dir.join("files")

        remote.fetch_files(keys, into: files_dir, storage_dir: storage_dir)

        keys.reject { |key| File.exist?(files_dir.join(key)) }
      end

      def bundle_dir
        Rails.root.join("db", "content_seeds", name)
      end
  end
end
