# frozen_string_literal: true

require "faraday"
require "json"
require "singleton"

module TraceStax
  module Sidekiq
    class Client
      include Singleton

      def initialize
        @queue   = Queue.new
        @mutex   = Mutex.new
        @running = false
      end

      def start
        @mutex.synchronize do
          return if @running

          @running = true
          @thread = Thread.new { flush_loop }
          @thread.abort_on_exception = false

          at_exit { shutdown }
        end
      end

      def send_event(payload)
        return unless config.enabled

        if config.dry_run
          puts "[tracestax dry-run] #{payload.to_json}"
          return
        end

        @queue.push(payload)
      end

      def flush
        batch = []
        batch.push(@queue.pop(true)) while !@queue.empty? && batch.size < config.max_batch_size
        return if batch.empty?

        conn = Faraday.new(url: config.endpoint) do |f|
          f.request :json
          f.adapter Faraday.default_adapter
        end

        batch.each do |event|
          endpoint = case event[:type]
                     when "task_event" then "/v1/ingest"
                     when "snapshot"   then "/v1/snapshot"
                     when "heartbeat"  then "/v1/heartbeat"
                     else "/v1/ingest"
                     end

          conn.post(endpoint) do |req|
            req.headers["Authorization"] = "Bearer #{config.api_key}"
            req.headers["Content-Type"]  = "application/json"
            req.body = event.to_json
          end
        rescue StandardError
          # Swallow send errors — monitoring should never break the app
        end
      rescue ThreadError
        # Queue empty
      end

      def shutdown
        @mutex.synchronize { @running = false }
        flush
      end

      private

      def config
        TraceStax::Sidekiq.configuration
      end

      def flush_loop
        while @running
          sleep(config.flush_interval)
          flush
        end
      rescue StandardError
        # Swallow unexpected errors in the background thread
      end
    end
  end
end
