# frozen_string_literal: true

require "socket"

module TraceStax
  class SolidQueueSubscriber
    def self.attach
      return unless defined?(SolidQueue)

      ActiveSupport::Notifications.subscribe("perform_start.solid_queue") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        Thread.current[:tracestax_start_time] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Thread.current[:tracestax_job_data] = event.payload
      end

      ActiveSupport::Notifications.subscribe("perform.solid_queue") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        start_time = Thread.current[:tracestax_start_time]
        job_data = Thread.current[:tracestax_job_data] || {}
        duration_ms = start_time ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round : nil

        payload = {
          framework: "solid_queue",
          language: "ruby",
          sdk_version: TraceStax::VERSION,
          type: "task_event",
          worker: {
            key: "#{Socket.gethostname}:#{Process.pid}",
            hostname: Socket.gethostname,
            pid: Process.pid,
            concurrency: SolidQueue.config&.dig(:workers, :threads) || 1,
            queues: Array(job_data[:queue_name] || "default")
          },
          task: {
            name: job_data[:job_class] || "unknown",
            id: job_data[:job_id]&.to_s || SecureRandom.uuid,
            queue: job_data[:queue_name] || "default",
            attempt: job_data[:executions] || 1
          },
          status: event.payload[:error] ? "failed" : "succeeded",
          metrics: {
            duration_ms: duration_ms
          }
        }

        if event.payload[:error]
          err = event.payload[:error]
          payload[:error] = {
            type: err.class.name,
            message: err.message,
            stack_trace: err.backtrace&.first(20)&.join("\n")
          }
        end

        TraceStax.client.send_event(payload)
      end
    end
  end
end
