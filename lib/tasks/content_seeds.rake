require "content_seeds/exporter"

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
end
