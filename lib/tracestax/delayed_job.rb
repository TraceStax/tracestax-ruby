# frozen_string_literal: true

require "socket"

module TraceStax
  module DelayedJob
    # Delayed::Job lifecycle plugin.
    #
    # Usage:
    #   Delayed::Worker.plugins << TraceStax::DelayedJob::Plugin
    class Plugin < Delayed::Plugin
      callbacks do |lifecycle|
        lifecycle.around(:perform) do |worker, job, &block|
          TraceStax::DelayedJob.around_perform(worker, job, &block)
        end
      end
    end

    def self.around_perform(worker, job, &block)
      client = TraceStax::Client.instance
      task_name = job.payload_object.class.name rescue "unknown"
      job_id = job.id.to_s
      queue = job.queue || "default"
      attempt = (job.attempts || 0) + 1

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      worker_info = {
        key: "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid: Process.pid,
        queues: [queue],
      }

      client.send_event({
        type: "task_event", framework: "delayed_job", language: "ruby",
        sdk_version: TraceStax::VERSION, status: "started",
        worker: worker_info,
        task: { name: task_name, id: job_id, queue: queue, attempt: attempt },
        metrics: {},
      })

      begin
        block.call(worker, job)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
        client.send_event({
          type: "task_event", framework: "delayed_job", language: "ruby",
          sdk_version: TraceStax::VERSION, status: "succeeded",
          worker: worker_info,
          task: { name: task_name, id: job_id, queue: queue, attempt: attempt },
          metrics: { duration_ms: duration_ms },
        })
      rescue => e
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
        client.send_event({
          type: "task_event", framework: "delayed_job", language: "ruby",
          sdk_version: TraceStax::VERSION, status: "failed",
          worker: worker_info,
          task: { name: task_name, id: job_id, queue: queue, attempt: attempt },
          metrics: { duration_ms: duration_ms },
          error: { type: e.class.name, message: e.message, stack_trace: e.backtrace&.first(20)&.join("\n") },
        })
        raise
      end
    end
  end
end
