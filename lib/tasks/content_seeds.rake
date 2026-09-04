require "content_seeds/exporter"
require "content_seeds/importer"

namespace :content_seeds do
  desc "Exports admin-created content from a remote host into db/content_seeds/<name>"
  task :export, [:host, :name, :since] do |_, args|
    host = args[:host] || abort("Usage: rake content_seeds:export[host,name,since]")
    name = args[:name] || abort("Usage: rake content_seeds:export[host,name,since]")

    report = ContentSeeds::Exporter.call(host: host, name: name, since: args[:since])

    puts "Exported '#{report.name}' from #{host} (since #{report.since})"
    report.counts.each { |dataset, count| puts "  #{dataset}: #{count}" }
    puts "  blobs copied: #{report.blobs_copied}"
    puts "  files skipped (older than FILES_SINCE, expected on the target): #{report.files_skipped}"

    if report.unresolved_urls.any?
      puts "Unresolved editor URLs (left untouched, needs a manual look):"
      report.unresolved_urls.each { |url| puts "  #{url}" }
    end

    if report.missing_files.any?
      puts "Missing files (blob known but no file copied):"
      report.missing_files.each { |key| puts "  #{key}" }
    end
  end

  print_import_report = lambda do |logger, report|
    report.counts.each { |dataset, count| logger.info("  #{dataset}: #{count}") }

    if report.skipped.any?
      logger.info("Skipped:")
      report.skipped.each { |s| logger.info("  [#{s.dataset}] #{s.natural_key}: #{s.message}") }
    end

    if report.unresolved_tokens.any?
      logger.info("Unresolved tokens:")
      report.unresolved_tokens.each { |t| logger.info("  #{t}") }
    end

    next if report.failures.empty?

    logger.warn("Failures:")
    report.failures.each { |f| logger.warn("  [#{f.dataset}] #{f.natural_key}: #{f.message}") }
  end

  # Shared body of every import task: resolves the bundle name and tenant,
  # runs the given block on an importer, prints the report and exits 1 when
  # any record failed.
  run_import = lambda do |task_name, args, &block|
    name = args[:name] || abort("Usage: rake #{task_name}[name,tenant]")
    logger = ApplicationLogger.new
    logger.info("#{task_name} '#{name}'")

    begin
      report = Tenant.switch(args[:tenant] || "public") { block.call(ContentSeeds::Importer.new(name: name)) }
      print_import_report.call(logger, report)
    rescue ContentSeeds::Importer::ImportFailed => e
      print_import_report.call(logger, e.report)
      exit 1
    end
  end

  # One task per import step, in the order they must run:
  #   1. blobs               5. pages
  #   2. ckeditor_pictures   6. content_blocks
  #   3. site_images         7. i18n_contents
  #   4. documents           8. cards
  #                          9. budget_extensions
  namespace :import do
    ContentSeeds::Importer::STEPS.each_with_index do |step, index|
      desc "Imports only the #{step.tr("_", " ")} of db/content_seeds/<name> " \
           "(step #{index + 1} of #{ContentSeeds::Importer::STEPS.size})"
      task step, [:name, :tenant] => :environment do |_, args|
        run_import.call("content_seeds:import:#{step}", args) { |importer| importer.run(step) }
      end
    end
  end

  desc "Imports a db/content_seeds/<name> bundle: " \
       "runs the #{ContentSeeds::Importer::STEPS.size} import steps in order"
  task :import, [:name, :tenant] => :environment do |_, args|
    run_import.call("content_seeds:import", args, &:call)
  end
end
