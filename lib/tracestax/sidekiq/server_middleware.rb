# frozen_string_literal: true

require "socket"

module TraceStax
  module Sidekiq
    class ServerMiddleware
      def call(worker, job, queue)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          yield
        rescue => err
          duration_ms = elapsed_ms(start_time)
          send_task_event(worker, job, queue, "failed", duration_ms, err)
          raise
        end

        duration_ms = elapsed_ms(start_time)
        send_task_event(worker, job, queue, "succeeded", duration_ms, nil)
      end

      private

      def elapsed_ms(start_time)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
      end

      def send_task_event(worker, job, queue, status, duration_ms, err)
        payload = {
          framework:   "sidekiq",
          language:    "ruby",
          sdk_version: TraceStax::Sidekiq::VERSION,
          type:        "task_event",
          worker: {
            key:         "#{Socket.gethostname}:#{Process.pid}",
            hostname:    Socket.gethostname,
            pid:         Process.pid,
            concurrency: sidekiq_concurrency,
            queues:      sidekiq_queue_names
          },
          task: {
            name:     job_class_name(worker, job),
            id:       job["jid"].to_s,
            queue:    queue.to_s,
            attempt:  (job["retry_count"] || 0) + 1,
            chain_id: job["bid"]
          }.compact,
          status:  status,
          metrics: { duration_ms: duration_ms }
        }

        if err
          payload[:error] = {
            type:        err.class.name,
            message:     err.message,
            stack_trace: err.backtrace&.first(20)&.join("\n")
          }
        end

        TraceStax::Sidekiq.client.send_event(payload)
      rescue StandardError
        # Swallow instrumentation errors — monitoring should never break the app
      end

      def job_class_name(worker, job)
        # Prefer the worker object's class name; fall back to the job hash's "class" key
        if worker.respond_to?(:class) && worker.class.name && worker.class.name != "Object"
          worker.class.name
        else
          job["class"].to_s
        end
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
    end
  end
end
