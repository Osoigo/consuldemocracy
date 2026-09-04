# Content seeds: export admin-created content from pre-production, import into production

Date: 2026-09-03. Branch: `content-seeds`. Status: implemented on branch `content-seeds` (2026-09-03); amended after backend planning (signed-id format, Marshal ids, content-block locales) and after code review (absolute editor URLs, cards keyed by owner, header singleton, blobs as natural key for documents and editor pictures, password over stdin).

## Goal

Move the static content that admins created on the Valencia pre-production
server (`ivlcparticipa-app1`) during the last 3 months into production, without
retyping it and without writing anything on the source server.

Deliverables:

1. `rake content_seeds:export[host,name,since]` — read-only extraction over SSH
   that produces a seed bundle under `db/content_seeds/<name>/`.
2. `rake content_seeds:import[name,tenant]` — idempotent import of a bundle into
   the current database (production), including files.
3. The bundle itself (`db/content_seeds/valencia_2026_09/`), committed to git so
   it can be deployed and imported on production.

## Non-goals

- `settings`, `widget_feeds`, banners, polls, legislation, user content.
- Pages that ship with the default seeds (`db/pages/*.rb`) unless they were
  created inside the window (they are matched by slug like any other page).
- Copying `secret_key_base` or any secret between servers.

## Hard constraints

- The source server is **read-only**: only `ssh` + `psql` `SELECT`s inside a
  session with `SET default_transaction_read_only = on`, plus `rsync`/`scp` from
  server to local. Nothing is written to the server filesystem, not even `/tmp`.
  No `rails runner` on the server.
- No secret is stored locally: DB connection parameters are read from the remote
  `config/database.yml` (production section) at run time and only kept in
  memory / the remote process environment.
- Production import must be re-runnable without creating duplicates.

## Data covered

Single tenant (`multitenancy: false` in `config/secrets.yml`), schema `public`.
All timestamps below are compared against `since` (default: 3 months before now).

| Content (colleague's list)              | Tables                                                             | Window rule                                                | Natural key on import                       |
|-----------------------------------------|--------------------------------------------------------------------|------------------------------------------------------------|---------------------------------------------|
| Custom pages ("Información")            | `site_customization_pages` + `_translations`                       | parent `updated_at` ≥ since OR any translation `updated_at` ≥ since | `slug`                                      |
| Documents (admin uploads)               | `documents` (`admin = true`, no documentable) + blob                | `updated_at` ≥ since, or referenced from exported HTML     | blob `key`                                  |
| Custom images                           | `site_customization_images` + blob (`name = 'image'`)               | blob `created_at` ≥ since                                  | `name` (singleton, always upsert)           |
| Homepage header + cards                 | `widget_cards` + `_translations` + `images` + blob                 | parent `updated_at` ≥ since OR any translation `updated_at` ≥ since | header: singleton; others: `cardable` + `link_url` + title |
| Custom texts (menu etc.)                | `i18n_contents` + `_translations`                                  | translation `updated_at` ≥ since (parent has no timestamps) | `key` (singleton, always upsert)            |
| Content blocks (footer, top links)      | `site_customization_content_blocks`                                | `updated_at` ≥ since                                       | `name` + `locale` (singleton, always upsert)|
| Budget custom stats/results             | `budget_extensions` + `_translations`                              | parent `updated_at` ≥ since OR any translation `updated_at` ≥ since | budget `slug`, fallback default-locale `name` |
| Images uploaded through the text editor | `ckeditor_assets` (`type = 'Ckeditor::Picture'`) + blob (`storage_data`, `record_type = 'Ckeditor::Asset'`) | referenced from any exported HTML **or** `updated_at` ≥ since | blob `key`                                  |
| Files                                   | `active_storage_blobs` + `active_storage_attachments`              | only blobs reachable from the rows above                   | blob `key` (reused verbatim)                |

Rationale: every table is filtered by modification (`updated_at` of the row or
of any of its translations; creation implies modification), so a bundle taken
with `since` = the date the target was copied from the source carries exactly
the delta, edits included. Custom images are filtered by blob creation because
a replaced image is a new blob.

Files: blobs are immutable, so with `FILES_SINCE=<copy date>` the exporter
lists every blob in `content.yml` but only copies the files of blobs created
since that date; the importer reuses the older ones by key without uploading
anything. Without `FILES_SINCE` every file is copied (empty target).

Not exported: `active_storage_variant_records` (variants regenerate on demand).

## Bundle format

```
db/content_seeds/<name>/
  content.yml
  files/<blob key>          # raw file, one per blob
```

`content.yml` top-level keys, in import order:

```yaml
meta: { exported_at, source_host, since, default_locale, locales: [es, ca, ...] }
blobs:              [{ key, filename, content_type, byte_size, checksum, metadata }]
ckeditor_pictures:  [{ blob_key, data_file_name, data_content_type, data_file_size, width, height }]
site_images:        [{ name, blob_key }]
documents:          [{ title, blob_key }]
pages:              [{ slug, status, more_info_flag, print_content_flag, locale,
                       translations: { es: { title, subtitle, content }, ... } }]
content_blocks:     [{ name, locale, body }]
i18n_contents:      [{ key, translations: { es: value, ... } }]
cards:              [{ header, columns, order, link_url,
                       cardable: null | { type: "SiteCustomization::Page", slug } | { type: "WebSection", name },
                       image: null | { blob_key, title },
                       translations: { es: { label, title, description, link_text }, ... } }]
budget_extensions:  [{ budget: { slug, name }, stats_override, results_extension,
                       translations: { es: { stats_override_content, results_extension_content }, ... } }]
```

Original numeric ids are never stored; everything is addressed by natural key or
blob key. Every exported parent carries **all** its translations.

### Portable references to editor images

HTML stored by CKEditor contains links signed with the source server's
`secret_key_base`, e.g.
`/rails/active_storage/representations/redirect/<signed_blob_id>/<signed_variation>/<filename>`
or `/rails/active_storage/blobs/redirect/<signed_blob_id>/<filename>`.

The exporter rewrites each of them into a portable token:

```
consul-seed://blob/<blob key>
consul-seed://blob/<blob key>?variant=<base64url(JSON transformations)>
```

Decoding does not need the secret. Verified against this app's own verifier
(`config.load_defaults 7.2`, JSON message serializer, `urls_expire_in` nil):

```
signed_blob_id  = base64("{\"_rails\":{\"data\":42,\"pur\":\"blob_id\"}}") + "--" + hmac
signed_variation = base64("{\"_rails\":{\"data\":{\"resize\":\"800>\"},\"pur\":\"variation\"}}") + "--" + hmac
```

The exporter takes the part before `--`, normalises the base64 alphabet,
parses the JSON, checks `pur` and reads `data` (falling back to the legacy
nested `message` envelope if `data` is absent). The HMAC is ignored: the data
comes from a trusted DB. Payloads that are not JSON (Rails 6.1-era Marshal ids,
which exist in this DB, hence `config/initializers/active_storage_message_rotator.rb`)
are **never** deserialised with `Marshal.load`; the URL is left untouched and
listed in the export report. Tokens also carry `&disposition=attachment` when
the source URL did, so download links stay download links.

The importer replaces tokens with freshly signed paths generated by the target
app: `rails_blob_path(blob, only_path: true)` or
`rails_representation_path(blob.variant(transformations), only_path: true)`.
Fields scanned for tokens: page `content`, card `description`, content block
`body`, i18n `value`, budget extension `*_content`.

## Exporter (`lib/content_seeds/exporter.rb`, task in `lib/tasks/content_seeds.rake`)

Inputs: `host` (ssh alias), `name` (bundle dir name), `since` (ISO date,
default `3.months.ago.to_date`), optional `FILES_SINCE` env (see above), optional `APP_DIR` env (default: the
Capistrano `current` directory discovered with `ls -d /var/www/*/current` or
similar; verified manually before first run).

Steps:

1. `ssh host cat APP_DIR/config/database.yml` → production `database`, `username`,
   `password`, `host`, `port`. Kept in memory only.
2. Run one `psql` session on the remote host (`ssh host env PGPASSWORD=… psql …`),
   beginning with `SET default_transaction_read_only = on;`. Each dataset is a
   single `SELECT json_agg(...)` returning JSON on stdout. SQL lives in one Ruby
   module so it can be unit-tested against the local test DB.
3. Build the bundle structure in memory, rewriting editor URLs into tokens and
   collecting the set of blob keys.
4. `rsync -a --files-from=<local list> host:APP_DIR/storage/ db/content_seeds/<name>/files/`
   using the `TenantDisk` layout `<key[0..1]>/<key[2..3]>/<key>` (public schema
   has no `tenants/` prefix). Files are stored flat by key in the bundle.
5. Write `content.yml` and print a report: rows per dataset, blobs copied,
   unresolved editor URLs, missing files.

The exporter never needs the local database; the rake task must not depend on
`:environment` for anything that touches the remote host.

## Importer (`lib/content_seeds/importer.rb`, `rake content_seeds:import[name,tenant]`)

Wrapped in `Tenant.switch(tenant || "public")` following `lib/tasks/db.rake`.
Order: blobs → ckeditor pictures → site images → documents → pages → content
blocks → i18n contents → cards → budget extensions. Each top-level record runs in
its own transaction; a failure is logged with the natural key and the import
continues, ending with a non-zero exit and a report (created / updated / skipped
/ failed per dataset).

Rules:

- Blob: `ActiveStorage::Blob.find_by(key:)` → reuse; else
  `ActiveStorage::Blob.create_and_upload!(io:, filename:, content_type:, key:, identify: false)`
  so the file goes through the configured service (TenantDisk).
- Owner user for `images`/`documents`: `Administrator.first.user` (fails fast with
  a clear message if there is no administrator).
- Entity tables (pages, documents, cards, ckeditor pictures, budget extensions):
  create when the natural key is absent; when present, skip, unless
  `OVERWRITE=1`, in which case attributes and translations are updated.
  Documents and editor pictures are keyed by **blob key** (the same key the
  HTML tokens point at), so the bundle's blob always ends up attached; an
  existing document is always skipped (`Document` cannot be re-saved without
  a `documentable`) and an existing picture only gets width/height refreshed.
  The homepage header card is a singleton (the app renders the oldest
  `header: true` row), so it maps onto the existing header. Other cards are
  keyed by owner (`cardable`) + `link_url` + title.
- Any blob created by the run that is attached to nothing at the end is
  reported as a failure (it would be purged by `files:remove_old_cached_attachments`).
- Singleton tables (site images, content blocks, i18n contents): always upsert.
- Budget extension whose budget cannot be found on the target: skipped and
  listed in the report by budget slug and name.
- Cards: `cardable` resolved by page slug / WebSection name; image created with
  `image_attributes` semantics (title, user, attachment = blob).
- Token rewriting happens right before saving each HTML field, after all blobs
  of the bundle exist.
- Translations are written with `Globalize.with_locale(locale)` for every locale
  in the bundle; Globalize stores them whether or not the locale is enabled on
  the target. The one exception is `SiteCustomization::ContentBlock`, whose model
  validates `locale` against `Setting.enabled_locales`: blocks for a locale not
  enabled on the target are skipped and listed in the report, and the importer
  never mutates `Setting`.

## Testing

- `spec/lib/content_seeds/signed_id_spec.rb`: encode with the app's own verifier
  (`ActiveStorage::Blob#signed_id`, `ActiveStorage::Variation.encode`) and assert
  the decoder recovers id / transformations without the secret.
- `spec/lib/content_seeds/exporter_spec.rb`: run the SQL builders against the
  local test DB with factory data on both sides of the window; assert the
  selection rules and the token rewriting.
- `spec/lib/content_seeds/importer_spec.rb`: fixture bundle under
  `spec/fixtures/content_seeds/sample/` (one page with an embedded editor image,
  one document, one site image, one header card with image, one i18n text, one
  content block, one budget extension). Assert: records created, files
  attached through TenantDisk, tokens rewritten to valid signed paths,
  second run creates nothing, `OVERWRITE=1` updates, missing budget is reported
  not raised.
- Rake task specs are limited to argument parsing / wiring.

## Operational notes

- `files:remove_old_cached_attachments` purges unattached blobs older than one
  day; the importer attaches every blob it creates in the same run, so only a
  crashed run can leave purgeable blobs behind.
- The bundle is plain YAML + files and can be reviewed in the PR before it is
  imported on production.
