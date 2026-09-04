# Content seeds

Bundles of admin-created content (custom pages, admin documents, site images,
homepage cards, i18n texts, content blocks, budget stats/results extensions and
the editor images they embed) exported from one Consul instance and importable
into another. Design notes: `docs/superpowers/specs/2026-09-03-content-seeds-design.md`.

Each bundle is a directory here:

```
db/content_seeds/<name>/content.yml   # records, addressed by natural keys
db/content_seeds/<name>/files/<key>   # one raw file per ActiveStorage blob
```

## Export (read-only against the source server)

Runs from a developer machine. Only `ssh` + `psql` `SELECT`s (in a
`default_transaction_read_only` session) and `rsync` from the server to the
local checkout; nothing is written on the server.

```bash
# optional: reuse an already authenticated ssh connection
ssh -fNM -o ControlPath=~/.ssh/cm-%h -o ControlPersist=4h ivlcparticipa-app1

SSH_OPTS="-o ControlPath=$HOME/.ssh/cm-%h" DB_ENV=preproduction \
  bin/rake "content_seeds:export[ivlcparticipa-app1,valencia_2026_09,2026-06-03]"
```

- `since` (third argument) is an ISO date; default: 3 months ago. A record is
  exported when it, or any of its translations, was created **or modified**
  since that date (singleton tables such as site images, i18n texts and
  content blocks: modified since).
- `FILES_SINCE=<ISO date>` skips copying the files of blobs created before
  that date: they are still listed in `content.yml` and the importer reuses
  them by key, so set it to the date the target was copied from the source.
  Without it every file is copied, which an empty target needs.
- `DB_ENV` selects the `config/database.yml` section on the server (`production` by default).
- `APP_DIR` / `STORAGE_DIR` override the discovered app dir (`/var/consul/current`) and its `storage/`.
- `DEFAULT_LOCALE` overrides the source's `locales.default` setting.
- Editor URLs (`/rails/active_storage/...`) are rewritten to `consul-seed://blob/<key>` tokens; any URL that
  could not be resolved is listed at the end and left untouched.

## Recommended flow when the target is a copy of the source

Production will start from a copy of the pre-production database (and its
`storage/`) migrated to 2.5.1, so the first import of a bundle taken at the
same time mostly reports "reused" and "skipped". The useful run is the delta
with whatever admins changed on pre-production after the copy:

```bash
# on a developer machine, once the copy has been taken on <copy date>
SSH_OPTS="-o ControlPath=$HOME/.ssh/cm-%h" DB_ENV=preproduction FILES_SINCE=<copy date> \
  bin/rake "content_seeds:export[ivlcparticipa-app1,valencia_delta,<copy date>]"

# on the target
RAILS_ENV=production OVERWRITE=1 bin/rake "content_seeds:import[valencia_delta]"
```

`OVERWRITE=1` is what makes an edited page, card or budget extension replace
the copy's version; without it existing records are skipped. The import only
adds and updates: records deleted on pre-production after the copy stay on the
target, a card whose title changed is imported as a new card next to the old
one, and a re-uploaded document is added as a new document.

## Import (on the target, e.g. production)

```bash
RAILS_ENV=production bin/rake "content_seeds:import[valencia_2026_09]"          # default tenant
RAILS_ENV=production bin/rake "content_seeds:import[valencia_2026_09,<tenant>]" # a specific tenant
```

The general task runs nine steps in dependency order, each also available as
its own task (`content_seeds:import:<step>[name,tenant]`) for running or
re-running one at a time. Earlier steps must have run first: a later step
that needs a blob not yet imported fails with "blob <key> was not imported".

| # | Task                                        | What it creates                                                  |
|---|---------------------------------------------|------------------------------------------------------------------|
| 1 | `content_seeds:import:blobs`                | ActiveStorage blobs + files, reused by key                       |
| 2 | `content_seeds:import:ckeditor_pictures`    | editor images (`Ckeditor::Picture`) attached to their blob       |
| 3 | `content_seeds:import:site_images`          | site customization images (logo, favicon, ...) by name           |
| 4 | `content_seeds:import:documents`            | admin documents (`Document`, `admin: true`) by blob              |
| 5 | `content_seeds:import:pages`                | custom pages by slug, with translations and re-signed HTML       |
| 6 | `content_seeds:import:content_blocks`       | content blocks by name + locale                                  |
| 7 | `content_seeds:import:i18n_contents`        | custom texts by key                                              |
| 8 | `content_seeds:import:cards`                | homepage header and cards with their images                      |
| 9 | `content_seeds:import:budget_extensions`    | budget stats/results extensions, linked to budgets by slug       |

Only the general task runs the final check for blobs left unattached; when
running steps by hand, finish the sequence the same day (the nightly
`files:remove_old_cached_attachments` purges unattached blobs older than a day).

Prerequisites on the target: at least one administrator (owner of imported
images/documents), the bundle's locales enabled (`es`, `val` for
`valencia_2026_09`), and the budgets the extensions belong to, matched by slug
(`presupuestos-participativos-2016-2017` ... `presupuestos-participativos-2025-2026`).

Behaviour:

- Re-runnable: blobs are reused by key (an existing, identical file is never
  uploaded again, and its file need not even be in the bundle), singleton
  tables (site images, i18n texts, content blocks) are always upserted, and
  pages / cards / documents / editor pictures / budget extensions that
  already exist are **skipped**.
- `OVERWRITE=1` updates existing pages, cards and budget extensions with the
  bundle's attributes and translations. Needed for `privacy`, `conditions` and
  `accessibility`, which the default seeds create on every instance, and for
  the homepage header: the app renders a single header card, so the bundle's
  header replaces the existing one only with `OVERWRITE=1` (without it, an
  existing header is kept and reported as skipped).
- Documents and editor images are matched by blob key, pages by slug, other
  cards by owner page + link + title, budget extensions by budget slug.
- Budget extensions whose budget is missing, and content blocks for a locale
  that is not enabled, are skipped and listed in the report (by budget slug or
  block name and locale).
- Each record is imported in its own transaction; failures are collected and
  the task exits with status 1 after printing them.
- Editor images inside HTML are re-signed with the target's own
  `secret_key_base`, so no `src` needs to be touched.

## Bundle `valencia_2026_09`

Exported on 2026-09-03 from `ivlcparticipa-app1` (pre-production, `since` 2026-06-03):
12 pages, 10 admin documents, 11 site images, 4 homepage cards (1 header + 3
with image), 7 budget extensions, 7 editor images, 2 i18n texts, 31 files (~12 MB).
