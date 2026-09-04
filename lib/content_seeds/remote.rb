require "open3"
require "shellwords"
require "yaml"
require "json"
require "tmpdir"
require "fileutils"
require "uri"

module ContentSeeds
  # All access to the source server: read-only SQL over SSH+psql and file
  # copies over rsync. Nothing here ever writes to the remote filesystem,
  # not even a temp file: the list of files to rsync is written to a LOCAL
  # tmpdir.
  #
  # `SSH_OPTS` (e.g. `-o ControlPath=~/.ssh/cm-%h`) is honoured by every
  # remote call, so an operator can reuse an already-authenticated
  # ControlMaster socket instead of prompting for credentials per call.
  # rsync re-splits its `-e` command on whitespace itself (and would choke
  # on shell escapes), so the options must not contain spaces.
  # `DB_ENV` selects which `database.yml` section to read (`production` by
  # default; some deployments name it e.g. `preproduction`).
  # `SEED_DB_HOST/PORT/NAME/USER/PASSWORD` override whatever is read from
  # the remote `database.yml`.
  class Remote
    class Error < StandardError; end

    attr_reader :host

    def initialize(host:, app_dir: nil, ssh_opts: ENV["SSH_OPTS"])
      @host = host
      @app_dir = app_dir
      @ssh_opts = Shellwords.split(ssh_opts.to_s)
    end

    def app_dir
      @app_dir ||= discover_app_dir
    end

    # Reads the remote `config/database.yml`'s section (`production` by
    # default; override with `DB_ENV`, e.g. `preproduction`). ERB is only
    # evaluated remotely, and only when the file actually contains it
    # (never fetched raw and eval'd locally): a small read-only `ruby -e`
    # one-liner renders it and prints JSON. A plain file (no ERB) is
    # parsed locally with `YAML.safe_load(aliases: true)`, which resolves
    # `<<: *default` merge keys natively.
    def database_config
      @database_config ||= complete_env_overrides ||
                           apply_env_overrides(normalize_database_config(database_yaml_section))
    end

    # Runs `sql` on the remote database inside a read-only session and
    # returns the raw stdout (one line of JSON, since callers always use
    # `-At` friendly, `json_agg`-shaped queries). `-q` keeps the `SET`
    # command tag of the read-only preamble out of stdout.
    #
    # The password never appears on a command line (visible in `ps` on both
    # ends): the remote shell reads it from the first line of stdin into
    # `PGPASSWORD`, and psql consumes the rest of stdin as the script.
    def query(sql)
      config = database_config
      psql = Shellwords.shelljoin([
        "psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
        "-h", config[:host].to_s,
        "-p", config[:port].to_s,
        "-U", config[:username].to_s,
        "-d", config[:database].to_s
      ])
      command = "IFS= read -r PGPASSWORD; export PGPASSWORD; exec #{psql}"
      stdin = "#{config[:password]}\n#{readonly_sql(sql)}"

      stdout, stderr, status = Open3.capture3(*ssh_argv(command), stdin_data: stdin)
      raise Error, "psql on #{host} failed: #{stderr}" unless status.success?

      stdout.strip
    end

    # Copies the blobs for `keys` from the remote storage service into the
    # local `into` directory, flat (`<into>/<key>`), using the same
    # `<key[0..1]>/<key[2..3]>/<key>` layout the disk service (and
    # `TenantDisk`, which is that layout with an optional tenant prefix
    # that's empty for the public schema) uses on both ends.
    def fetch_files(keys, into:, storage_dir: "#{app_dir}/storage")
      return if keys.empty?

      FileUtils.mkdir_p(into)

      Dir.mktmpdir do |dir|
        list_path = File.join(dir, "files")
        File.write(list_path, keys.map { |key| relative_path_for(key) }.join("\n"))

        argv = [
          "rsync", "-a", "--files-from=#{list_path}", "--no-relative",
          "-e", ["ssh", "-o", "BatchMode=yes", *@ssh_opts].join(" "),
          "#{host}:#{storage_dir}/", "#{into}/"
        ]
        _stdout, stderr, status = Open3.capture3(*argv)
        raise Error, "rsync from #{host} failed: #{stderr}" unless rsync_ok?(status)
      end
    end

    private

      APP_DIR_CANDIDATES = ["/var/consul/current", "/var/www/*/current"].freeze
      # 23 = partial transfer (some source files missing), 24 = files vanished
      # during the transfer. Both still copy everything else, and the caller
      # checks which keys are missing locally.
      RSYNC_PARTIAL_EXIT_CODES = [23, 24].freeze

      def rsync_ok?(status)
        status.success? || RSYNC_PARTIAL_EXIT_CODES.include?(status.exitstatus)
      end

      def discover_app_dir
        APP_DIR_CANDIDATES.each do |glob|
          dirs = list_dirs(glob)
          return dirs.first if dirs.size == 1
        end

        tried = APP_DIR_CANDIDATES.join(", ")
        raise Error, "could not discover a unique app dir on #{host} (tried #{tried}); set APP_DIR explicitly"
      end

      def list_dirs(glob)
        run("ls -d #{glob} 2>/dev/null || true").split("\n").map(&:strip).reject(&:empty?)
      end

      def cat(path)
        run(Shellwords.shelljoin(["cat", path]))
      end

      def database_yaml_section
        path = "#{app_dir}/config/database.yml"
        raw = cat(path)

        raw.include?("<%") ? resolve_erb_database_yaml(path) : parse_database_yaml(raw)
      end

      def run(command)
        stdout, stderr, status = Open3.capture3(*ssh_argv(command))
        raise Error, "ssh #{host} failed: #{stderr}" unless status.success?

        stdout
      end

      def ssh_argv(command)
        ["ssh", "-o", "BatchMode=yes", *@ssh_opts, host, command]
      end

      def readonly_sql(sql)
        "SET default_transaction_read_only = on;\n#{sql}"
      end

      def relative_path_for(key)
        File.join(key[0..1], key[2..3], key)
      end

      def db_env
        ENV["DB_ENV"].presence || "production"
      end

      def parse_database_yaml(raw)
        data = YAML.safe_load(raw, aliases: true, permitted_classes: [Symbol])
        (data[db_env] || data[db_env.to_sym] || {}).transform_keys(&:to_s)
      end

      def resolve_erb_database_yaml(path)
        script = <<~RUBY
          require "yaml"; require "erb"; require "json"
          content = File.read(#{path.inspect})
          data = YAML.safe_load(ERB.new(content).result, aliases: true, permitted_classes: [Symbol])
          section = data[#{db_env.inspect}] || data[#{db_env.to_sym.inspect}] || {}
          puts JSON.generate(section)
        RUBY
        command = Shellwords.shelljoin(["ruby", "-ryaml", "-rerb", "-rjson", "-e", script])

        JSON.parse(run(command))
      end

      def normalize_database_config(production)
        if production["url"].present?
          parse_database_url(production["url"])
        else
          {
            host: production["host"],
            port: production["port"],
            database: production["database"],
            username: production["username"],
            password: production["password"]
          }
        end
      end

      def parse_database_url(url)
        uri = URI.parse(url)

        {
          host: uri.host,
          port: uri.port,
          database: unescape(uri.path.delete_prefix("/")),
          username: unescape(uri.user),
          password: unescape(uri.password)
        }
      end

      # URI components come back percent-encoded (`p%40ss` for `p@ss`).
      def unescape(component)
        component && URI::DEFAULT_PARSER.unescape(component)
      end

      # When SEED_DB_HOST/NAME/USER/PASSWORD are all given, the remote
      # database.yml is not read at all (it may need the app's environment
      # to render, which a plain ssh session does not have).
      def complete_env_overrides
        required = %w[SEED_DB_HOST SEED_DB_NAME SEED_DB_USER SEED_DB_PASSWORD]
        return nil unless required.all? { |name| ENV[name].present? }

        apply_env_overrides({ port: nil })
      end

      def apply_env_overrides(config)
        {
          host: ENV["SEED_DB_HOST"].presence || config[:host],
          port: ENV["SEED_DB_PORT"].presence || config[:port],
          database: ENV["SEED_DB_NAME"].presence || config[:database],
          username: ENV["SEED_DB_USER"].presence || config[:username],
          password: ENV["SEED_DB_PASSWORD"].presence || config[:password]
        }
      end
  end
end
