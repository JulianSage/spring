module Spring
  class << self
    attr_reader :original_env
  end
  @original_env = ENV.to_hash
end

require "socket"
require "thread"

require "spring/configuration"
require "spring/env"
require "spring/application_manager"
require "spring/process_title_updater"
require "spring/json"

# Must be last, as it requires bundler/setup
require "spring/commands"

# readline must be required before we setpgid, otherwise the require may hang,
# if readline has been built against libedit. See issue #70.
require "readline"

module Spring
  class Server
    def self.boot
      new.boot
    end

    attr_reader :env

    def initialize(env = Env.new)
      @env          = env
      @applications = Hash.new { |h, k| h[k] = ApplicationManager.new(self, k) }
      @pidfile      = env.pidfile_path.open('a')
      @mutex        = Mutex.new
    end

    def log(message)
      env.log "[server] #{message}"
    end

    def boot
      Spring.verify_environment

      write_pidfile
      set_pgid
      ignore_signals
      set_exit_hook
      set_process_title
      watch_bundle
      start_server
    end

    def start_server
      server = UNIXServer.open(env.socket_name)
      log "started on #{env.socket_name}"
      loop { serve server.accept }
    end

    def serve(client)
      log "accepted client"
      client.puts env.version

      app_client = client.recv_io
      command    = JSON.load(client.read(client.gets.to_i))

      args, default_rails_env = command.values_at('args', 'default_rails_env')

      if Spring.command?(args.first)
        log "running command #{args.first}"
        client.puts
        client.puts @applications[rails_env_for(args, default_rails_env)].run(app_client)
      else
        log "command not found #{args.first}"
        client.close
      end
    rescue SocketError => e
      raise e unless client.eof?
    ensure
      redirect_output
    end

    def rails_env_for(args, default_rails_env)
      Spring.command(args.first).env(args.drop(1)) || default_rails_env
    end

    # Boot the server into the process group of the current session.
    # This will cause it to be automatically killed once the session
    # ends (i.e. when the user closes their terminal).
    def set_pgid
      Process.setpgid(0, SID.pgid)
    end

    # Ignore SIGINT and SIGQUIT otherwise the user typing ^C or ^\ on the command line
    # will kill the server/application.
    def ignore_signals
      IGNORE_SIGNALS.each { |sig| trap(sig, "IGNORE") }
    end

    def set_exit_hook
      server_pid = Process.pid

      # We don't want this hook to run in any forks of the current process
      at_exit { shutdown if Process.pid == server_pid }
    end

    def shutdown
      @applications.values.each(&:stop)

      [env.socket_path, env.pidfile_path].each do |path|
        if path.exist?
          path.unlink rescue nil
        end
      end
    end

    def write_pidfile
      if @pidfile.flock(File::LOCK_EX | File::LOCK_NB)
        @pidfile.truncate(0)
        @pidfile.write("#{Process.pid}\n")
        @pidfile.fsync
      else
        exit 1
      end
    end

    # We need to redirect STDOUT and STDERR, otherwise the server will
    # keep the original FDs open which would break piping. (e.g.
    # `spring rake -T | grep db` would hang forever because the server
    # would keep the stdout FD open.)
    def redirect_output
      [STDOUT, STDERR].each { |stream| stream.reopen(env.log_file) }
    end

    def set_process_title
      ProcessTitleUpdater.run { |distance|
        "spring server | #{env.app_name} | started #{distance} ago"
      }
    end

    def watch_bundle
      @bundle_mtime = env.bundle_mtime
    end

    def application_starting
      @mutex.synchronize { exit if env.bundle_mtime != @bundle_mtime }
    end
  end
end
