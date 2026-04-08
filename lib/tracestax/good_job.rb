# frozen_string_literal: true

require "socket"

module TraceStax
  module GoodJob
    # ActiveSupport::Notifications subscriber for Good Job.
    #
    # Usage:
    #   TraceStax::GoodJob.subscribe!
    def self.subscribe!
      ActiveSupport::Notifications.subscribe("perform.good_job") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        handle_perform(event)
      end
    end

    def self.handle_perform(event)
      client = TraceStax::Client.instance
      payload = event.payload
      job = payload[:good_job] || payload[:job]

      task_name = job&.job_class || job&.class&.name || "unknown"
      job_id = job&.good_job_concurrency_key || job&.provider_job_id || SecureRandom.uuid
      queue = job&.queue_name || "default"
      attempt = (job&.executions || 0) + 1
      duration_ms = (event.duration || 0).round

      worker_info = {
        key: "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid: Process.pid,
        queues: [queue],
      }

      error = event.payload[:error] || event.payload[:exception_object]
      status = error ? "failed" : "succeeded"

      event_payload = {
        type: "task_event", framework: "good_job", language: "ruby",
        sdk_version: TraceStax::VERSION, status: status,
        worker: worker_info,
        task: { name: task_name, id: job_id.to_s, queue: queue, attempt: attempt },
        metrics: { duration_ms: duration_ms },
      }

      if error
        event_payload[:error] = {
          type: error.class.name,
          message: error.message,
          stack_trace: error.backtrace&.first(20)&.join("\n"),
        }
      end

      client.send_event(event_payload)
    rescue => e
      # Never crash the host app
      $stderr.puts "[tracestax] GoodJob tracking error: #{e.message}"
    end
  end
end
