# frozen_string_literal: true

require "socket"

module TraceStax
  module Resque
    # Include this module in your Resque job classes, or use the global hook.
    #
    # Usage (per-job):
    #   class OrderProcessor
    #     extend TraceStax::Resque::Job
    #     def self.perform(order_id) ... end
    #   end
    #
    # Usage (global — all jobs):
    #   Resque.before_fork { TraceStax::Client.instance.start }
    #   Resque::Job.send(:extend, TraceStax::Resque::Job)
    module Job
      def around_perform_tracestax(*args)
        client = TraceStax::Client.instance
        job_id = args.first&.to_s || SecureRandom.uuid
        task_name = self.name
        queue = ::Resque.queue_from_class(self) || "default"

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        client.send_event({
          type: "task_event",
          framework: "resque",
          language: "ruby",
          sdk_version: TraceStax::VERSION,
          status: "started",
          worker: build_worker_info,
          task: { name: task_name, id: job_id, queue: queue.to_s, attempt: 1 },
          metrics: {},
        })

        begin
          yield
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          client.send_event({
            type: "task_event",
            framework: "resque",
            language: "ruby",
            sdk_version: TraceStax::VERSION,
            status: "succeeded",
            worker: build_worker_info,
            task: { name: task_name, id: job_id, queue: queue.to_s, attempt: 1 },
            metrics: { duration_ms: duration_ms },
          })
        rescue => e
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          client.send_event({
            type: "task_event",
            framework: "resque",
            language: "ruby",
            sdk_version: TraceStax::VERSION,
            status: "failed",
            worker: build_worker_info,
            task: { name: task_name, id: job_id, queue: queue.to_s, attempt: 1 },
            metrics: { duration_ms: duration_ms },
            error: { type: e.class.name, message: e.message, stack_trace: e.backtrace&.first(20)&.join("\n") },
          })
          raise
        end
      end

      private

      def build_worker_info
        {
          key: "#{Socket.gethostname}:#{Process.pid}",
          hostname: Socket.gethostname,
          pid: Process.pid,
          queues: [::Resque.queue_from_class(self) || "default"].map(&:to_s),
        }
      end
    end
  end
end
