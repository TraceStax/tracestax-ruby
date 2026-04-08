# frozen_string_literal: true

require "socket"

module TraceStax
  module Sidekiq
    class HeartbeatPoller
      INTERVAL = 60 # seconds

      def self.start
        new.start
      end

      def start
        @thread = Thread.new { poll_loop }
        @thread.abort_on_exception = false
        self
      end

      private

      def poll_loop
        loop do
          sleep(INTERVAL)
          send_heartbeat
          send_snapshots
        end
      rescue StandardError
        # Swallow unexpected errors — monitoring should never break the app
      end

      def send_heartbeat
        payload = {
          framework:   "sidekiq",
          language:    "ruby",
          sdk_version: TraceStax::Sidekiq::VERSION,
          timestamp:   Time.now.utc.iso8601,
          worker: {
            key:         "#{Socket.gethostname}:#{Process.pid}",
            hostname:    Socket.gethostname,
            pid:         Process.pid,
            queues:      sidekiq_queue_names,
            concurrency: sidekiq_concurrency
          }
        }

        TraceStax::Sidekiq.client.send_event(payload.merge(type: "heartbeat"))
      rescue StandardError
        # Swallow instrumentation errors — monitoring should never break the app
      end

      def send_snapshots
        ::Sidekiq::Queue.all.each do |q|
          payload = {
            framework:         "sidekiq",
            language:          "ruby",
            sdk_version:       TraceStax::Sidekiq::VERSION,
            timestamp:         Time.now.utc.iso8601,
            type:              "snapshot",
            queue_name:        q.name,
            depth:             q.size,
            throughput_per_min: q.latency.round(3)
          }
          TraceStax::Sidekiq.client.send_event(payload)
        end
      rescue StandardError
        # Swallow instrumentation errors — monitoring should never break the app
      end

      def sidekiq_concurrency
        ::Sidekiq.default_configuration[:concurrency]
      rescue StandardError
        nil
      end

      def sidekiq_queue_names
        ::Sidekiq::Queue.all.map(&:name)
      rescue StandardError
        []
      end

      def queue_stats
        ::Sidekiq::Queue.all.map do |q|
          { name: q.name, depth: q.size, latency: q.latency.round(3) }
        end
      rescue StandardError
        []
      end
    end
  end
end
