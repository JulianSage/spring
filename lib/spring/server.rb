require "socket"

require "spring/env"
require "spring/application_manager"

class Spring
  class Server
    def self.boot
      new.boot
    end

    attr_reader :env

    def initialize(env = Env.new)
      @env          = env
      @applications = Hash.new { |h, k| h[k] = ApplicationManager.new(k) }
    end

    def boot
      # Ignore SIGINT, otherwise the user typing ^C on the command line
      # will kill the background server.
      trap("INT", "IGNORE")

      set_exit_hook
      write_pidfile

      server = UNIXServer.open(env.socket_name)
      loop { @applications[server.accept.read].run server.accept }
    end

    def set_exit_hook
      server_pid = Process.pid

      at_exit do
        # We don't want this hook to run in any forks of the current process
        if Process.pid == server_pid
          [env.socket_path, env.pidfile_path].each do |path|
            path.unlink if path.exist?
          end
        end
      end
    end

    def write_pidfile
      file = env.pidfile_path.open('a')

      if file.flock(File::LOCK_EX | File::LOCK_NB)
        file.truncate(0)
        file.write("#{Process.pid}\n")
        file.fsync
      else
        STDERR.puts "#{file.path} is locked; it looks like a server is already running"
        exit(1)
      end
    end
  end
end

Spring::Server.boot if __FILE__ == $0
