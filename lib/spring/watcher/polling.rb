module Spring
  module Watcher
    class Polling < Abstract
      attr_reader :mtime

      def initialize(root, latency)
        super
        @mtime  = nil
        @poller = nil
      end

      def start
        unless @poller
          @mtime  = compute_mtime
          @poller = Thread.new {
            loop do
              sleep latency
              mark_stale if mtime < compute_mtime
            end
          }
        end
      end

      def stop
        if @poller
          @poller.kill
          @poller = nil
        end
      end

      def running?
        @poller
      end

      private

      def compute_mtime
        expanded_files.map { |f| File.mtime(f).to_f }.max || 0
      rescue Errno::ENOENT
        # if a file does no longer exist, the watcher is always stale.
        Float::MAX
      end

      def expanded_files
        files + Dir["{#{directories.join(",")}}"]
      end
    end
  end
end
