module ContentSeeds
  # Builds the read-only SQL used to export content. Every public method
  # returns a plain SQL string of the shape
  # `SELECT COALESCE(json_agg(r), '[]'::json) FROM ( ... ) r`, so it can be
  # run standalone (as each dataset spec does, against the local test
  # database) or embedded as a scalar subquery inside `bundle`, which
  # fetches every "since"-windowed dataset in a single round trip.
  #
  # Nothing here ever interpolates a value it hasn't validated first:
  # `since` must parse as an ISO date, blob ids must parse as integers,
  # blob keys and locales must match a narrow character class. There is no
  # bind-parameter support because this SQL is sent to `psql` over stdin.
  module SQL
    class << self
      def pages(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT
              p.slug,
              p.status,
              p.more_info_flag,
              p.print_content_flag,
              p.locale,
              (
                SELECT json_object_agg(t.locale, json_build_object(
                  'title', t.title, 'subtitle', t.subtitle, 'content', t.content
                ))
                FROM site_customization_page_translations t
                WHERE t.site_customization_page_id = p.id
              ) AS translations
            FROM site_customization_pages p
            WHERE p.updated_at >= '#{since}'::timestamp
               OR EXISTS (
                 SELECT 1 FROM site_customization_page_translations t2
                 WHERE t2.site_customization_page_id = p.id AND t2.updated_at >= '#{since}'::timestamp
               )
            ORDER BY p.slug
          ) r
        SQL
      end

      def documents(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT d.title, b.key AS blob_key
            FROM documents d
            JOIN active_storage_attachments a
              ON a.record_type = 'Document' AND a.record_id = d.id AND a.name = 'attachment'
            JOIN active_storage_blobs b ON b.id = a.blob_id
            WHERE d.admin = true AND d.documentable_id IS NULL AND d.updated_at >= '#{since}'::timestamp
            ORDER BY d.title, b.key
          ) r
        SQL
      end

      def site_images(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT si.name, b.key AS blob_key
            FROM site_customization_images si
            JOIN active_storage_attachments a
              ON a.record_type = 'SiteCustomization::Image' AND a.record_id = si.id AND a.name = 'image'
            JOIN active_storage_blobs b ON b.id = a.blob_id
            WHERE b.created_at >= '#{since}'::timestamp
            ORDER BY si.name
          ) r
        SQL
      end

      def content_blocks(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT cb.name, cb.locale, cb.body
            FROM site_customization_content_blocks cb
            WHERE cb.updated_at >= '#{since}'::timestamp
            ORDER BY cb.name, cb.locale
          ) r
        SQL
      end

      def i18n_contents(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT
              ic.key,
              (
                SELECT json_object_agg(t.locale, t.value)
                FROM i18n_content_translations t
                WHERE t.i18n_content_id = ic.id
              ) AS translations
            FROM i18n_contents ic
            WHERE EXISTS (
              SELECT 1 FROM i18n_content_translations t2
              WHERE t2.i18n_content_id = ic.id AND t2.updated_at >= '#{since}'::timestamp
            )
            ORDER BY ic.key
          ) r
        SQL
      end

      def cards(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT
              c.header,
              c.columns,
              c."order",
              c.link_url,
              CASE
                WHEN c.cardable_id IS NULL THEN NULL
                WHEN c.cardable_type = 'SiteCustomization::Page' THEN (
                  SELECT json_build_object('type', 'SiteCustomization::Page', 'slug', p.slug)
                  FROM site_customization_pages p WHERE p.id = c.cardable_id
                )
                WHEN c.cardable_type = 'WebSection' THEN (
                  SELECT json_build_object('type', 'WebSection', 'name', ws.name)
                  FROM web_sections ws WHERE ws.id = c.cardable_id
                )
                ELSE json_build_object('type', c.cardable_type)
              END AS cardable,
              (
                SELECT json_build_object('blob_key', b.key, 'title', img.title)
                FROM images img
                JOIN active_storage_attachments a
                  ON a.record_type = 'Image' AND a.record_id = img.id AND a.name = 'attachment'
                JOIN active_storage_blobs b ON b.id = a.blob_id
                WHERE img.imageable_type = 'Widget::Card' AND img.imageable_id = c.id
                LIMIT 1
              ) AS image,
              (
                SELECT json_object_agg(t.locale, json_build_object(
                  'label', t.label, 'title', t.title, 'description', t.description, 'link_text', t.link_text
                ))
                FROM widget_card_translations t
                WHERE t.widget_card_id = c.id
              ) AS translations
            FROM widget_cards c
            WHERE c.updated_at >= '#{since}'::timestamp
               OR EXISTS (
                 SELECT 1 FROM widget_card_translations t2
                 WHERE t2.widget_card_id = c.id AND t2.updated_at >= '#{since}'::timestamp
               )
            ORDER BY c.link_url, c.id
          ) r
        SQL
      end

      def budget_extensions(since:, default_locale:)
        since = normalize_since(since)
        default_locale = validate_locale!(default_locale)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            SELECT
              be.stats_override,
              be.results_extension,
              json_build_object(
                'slug', bu.slug,
                'name', COALESCE(
                  (
                    SELECT bt.name FROM budget_translations bt
                    WHERE bt.budget_id = bu.id AND bt.locale = '#{default_locale}'
                    LIMIT 1
                  ),
                  (
                    SELECT bt2.name FROM budget_translations bt2
                    WHERE bt2.budget_id = bu.id
                    ORDER BY bt2.locale
                    LIMIT 1
                  )
                )
              ) AS budget,
              (
                SELECT json_object_agg(t.locale, json_build_object(
                  'stats_override_content', t.stats_override_content,
                  'results_extension_content', t.results_extension_content
                ))
                FROM budget_extension_translations t
                WHERE t.budget_extension_id = be.id
              ) AS translations
            FROM budget_extensions be
            JOIN budgets bu ON bu.id = be.budget_id
            WHERE be.updated_at >= '#{since}'::timestamp
               OR EXISTS (
                 SELECT 1 FROM budget_extension_translations t2
                 WHERE t2.budget_extension_id = be.id AND t2.updated_at >= '#{since}'::timestamp
               )
            ORDER BY bu.slug
          ) r
        SQL
      end

      def ckeditor_pictures(since:)
        since = normalize_since(since)

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            #{ckeditor_pictures_select("cp.updated_at >= '#{since}'::timestamp")}
          ) r
        SQL
      end

      def ckeditor_pictures_for_blob_ids(ids)
        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            #{ckeditor_pictures_select(in_clause("b.id", validate_ids!(ids)))}
          ) r
        SQL
      end

      # Admin documents (no documentable) whose blob is one of `ids`,
      # whatever their creation date: a page inside the window may link a
      # PDF uploaded long before it, and that document must travel with
      # the page or its blob would be imported unattached.
      def documents_for_blob_ids(ids)
        <<~SQL
          SELECT COALESCE(json_agg(r ORDER BY r.title, r.blob_key), '[]'::json) FROM (
            SELECT d.title, b.key AS blob_key
            FROM documents d
            JOIN active_storage_attachments a
              ON a.record_type = 'Document' AND a.record_id = d.id AND a.name = 'attachment'
            JOIN active_storage_blobs b ON b.id = a.blob_id
            WHERE d.admin AND d.documentable_id IS NULL AND #{in_clause("b.id", ids.map { |id| Integer(id) })}
          ) r
        SQL
      end

      def blobs_by_ids(ids)
        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            #{blobs_select(in_clause("b.id", validate_ids!(ids)))}
          ) r
        SQL
      end

      def blobs_by_keys(keys)
        quoted_keys = keys.map { |key| "'#{validate_key!(key)}'" }

        <<~SQL
          SELECT COALESCE(json_agg(r), '[]'::json) FROM (
            #{blobs_select(in_clause("b.key", quoted_keys))}
          ) r
        SQL
      end

      # Composes the eight datasets that only depend on `since` into a
      # single JSON round trip. `ckeditor_pictures_for_blob_ids`,
      # `blobs_by_ids` and `blobs_by_keys` are deliberately left out: they
      # depend on the blob ids referenced from the HTML this first round
      # trip returns, so they can only run afterwards.
      def bundle(since:, default_locale:)
        <<~SQL
          SELECT json_build_object(
            'pages', (#{pages(since: since)}),
            'documents', (#{documents(since: since)}),
            'site_images', (#{site_images(since: since)}),
            'content_blocks', (#{content_blocks(since: since)}),
            'i18n_contents', (#{i18n_contents(since: since)}),
            'cards', (#{cards(since: since)}),
            'budget_extensions', (#{budget_extensions(since: since, default_locale: default_locale)}),
            'ckeditor_pictures', (#{ckeditor_pictures(since: since)})
          )
        SQL
      end

      # Value of one row of the `settings` table (NULL/absent → empty
      # string), used to read the source's default locale. `key` is
      # restricted to setting-key characters before interpolation.
      def setting_value(key)
        raise ArgumentError, "invalid setting key #{key.inspect}" unless key.to_s.match?(/\A[a-z0-9_.\-]+\z/i)

        "SELECT COALESCE((SELECT value FROM settings WHERE key = '#{key}' LIMIT 1), '')"
      end

      def normalize_since(since)
        Date.iso8601(since.to_s).iso8601
      end

      private

        def ckeditor_pictures_select(condition)
          <<~SQL
            SELECT b.key AS blob_key, cp.data_file_name, cp.data_content_type, cp.data_file_size,
                   cp.width, cp.height
            FROM ckeditor_assets cp
            JOIN active_storage_attachments a
              ON a.record_type = 'Ckeditor::Asset' AND a.record_id = cp.id AND a.name = 'storage_data'
            JOIN active_storage_blobs b ON b.id = a.blob_id
            WHERE cp.type = 'Ckeditor::Picture' AND #{condition}
            ORDER BY b.key
          SQL
        end

        # `id` is included so callers resolving a set of blob ids (an
        # editor URL only carries the id, never the key) can rebuild an
        # id => key map; it's simply unused/dropped by callers that only
        # need the key => metadata shape for the final bundle.
        def blobs_select(condition)
          <<~SQL
            SELECT b.id, b.key, b.filename, b.content_type, b.byte_size, b.checksum, b.metadata, b.created_at
            FROM active_storage_blobs b
            WHERE #{condition}
            ORDER BY b.key
          SQL
        end

        def in_clause(column, values)
          return "FALSE" if values.empty?

          "#{column} IN (#{values.join(",")})"
        end

        def validate_ids!(ids)
          ids.map { |id| Integer(id) }
        end

        def validate_key!(key)
          key = key.to_s
          raise ArgumentError, "invalid blob key: #{key.inspect}" unless key.match?(/\A[a-zA-Z0-9_-]+\z/)

          key
        end

        def validate_locale!(locale)
          locale = locale.to_s
          raise ArgumentError, "invalid locale: #{locale.inspect}" unless locale.match?(/\A[a-zA-Z-]+\z/)

          locale
        end
    end
  end
end
