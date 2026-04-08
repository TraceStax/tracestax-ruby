# frozen_string_literal: true

require "faraday"
require "json"
require "singleton"
require "socket"

module TraceStax
  # Resilience constants
  CIRCUIT_OPEN_THRESHOLD = 3
  CIRCUIT_COOLDOWN_SECS  = 30
  MAX_FLUSH_INTERVAL     = 60

  class Client
    include Singleton

    def initialize
      @queue          = Queue.new
      @mutex          = Mutex.new
      @running        = false
      @dropped_events = 0

      # Used for cooperative shutdown: signals flush_loop to wake and exit cleanly.
      @shutdown_mutex = Mutex.new
      @shutdown_cv    = ConditionVariable.new

      # Resilience state
      @consecutive_failures   = 0
      @circuit_state          = :closed # :closed | :open | :half_open
      @circuit_opened_at      = nil
      @current_flush_interval = nil # lazy-initialised from config
      @pause_until            = nil # Time or nil

      # Fork safety: track the PID so we can detect when we've been forked.
      # Checked on every public call; if the PID has changed we discard the
      # inherited (potentially poisoned) mutexes and respawn the daemon thread.
      @pid = Process.pid
    end

    def start
      @mutex.synchronize do
        return if @running

        @running                = true
        @current_flush_interval = config&.flush_interval || 5
        @thread                 = Thread.new { flush_loop }
        @thread.abort_on_exception = false

        at_exit { shutdown }
      end
    end

    def send_event(payload)
      reinitialize_if_forked!
      return unless config&.enabled

      # Guard against huge or non-serializable payloads that would OOM or raise
      # at flush time, potentially poisoning an entire batch of valid events.
      begin
        serialized = payload.to_json
      rescue StandardError
        $stderr.puts("[tracestax] send_event: payload not serializable, dropping")
        return
      end
      if serialized.bytesize > 512 * 1024
        $stderr.puts("[tracestax] send_event: payload exceeds 512 KB, dropping")
        return
      end

      if config&.dry_run
        begin
          $stdout.puts("[tracestax dry-run] #{serialized}")
        rescue StandardError
          # $stdout.puts may raise IOError in daemonized processes
        end
        return
      end

      # Prevent unbounded memory growth: drop oldest events when queue is full
      if @queue.size > 10_000
        trimmed = @queue.size - 5_000
        trimmed.times { @queue.pop(true) rescue nil }
        @mutex.synchronize { @dropped_events += trimmed }
      end

      @queue.push(payload)
    end

    # Returns a snapshot of the client's internal health metrics.
    # Keys: :queue_size, :dropped_events, :circuit_state, :consecutive_failures.
    def stats
      @mutex.synchronize do
        {
          queue_size:           @queue.size,
          dropped_events:       @dropped_events,
          circuit_state:        @circuit_state,
          consecutive_failures: @consecutive_failures,
        }
      end
    end

    # Sends a heartbeat synchronously and returns the directives hash (or nil on error).
    def send_heartbeat_sync(payload)
      return nil unless config&.enabled
      return nil if config&.dry_run

      result = post_for_json("/v1/heartbeat", payload)
      result&.dig("directives")
    end

    # Pauses ingest flushing until +epoch_ms+ (epoch milliseconds).
    def set_pause_until(epoch_ms)
      @mutex.synchronize { @pause_until = Time.at(epoch_ms / 1000.0) }
    end

    # Executes a server-issued command hash. Currently supports "thread_dump".
    def execute_command(cmd)
      return unless cmd["type"] == "thread_dump"

      wk = worker_key_for_dump
      dump = capture_thread_dump
      post_for_json("/v1/dump", {
        cmd_id:      cmd["id"],
        worker_key:  wk,
        dump_text:   dump,
        language:    "ruby",
        sdk_version: TraceStax::VERSION,
        captured_at: Time.now.utc.iso8601,
      })
    rescue StandardError
      # Dump capture must never raise into the host process
    end

    # Starts a background thread that POSTs a heartbeat to /v1/heartbeat every
    # +interval+ seconds. The thread is daemonised and swallows all errors so it
    # can never affect the host process.
    #
    # @param worker_key  [String]  unique identifier for this worker process
    # @param queues      [Array<String>] queue names this worker consumes
    # @param concurrency [Integer] number of concurrent threads/fibers
    # @param interval    [Integer] seconds between heartbeats (default: 30)
    def start_heartbeat_thread(worker_key:, queues:, concurrency:, interval: 30)
      thread = Thread.new do
        loop do
          sleep(interval)
          begin
            payload = {
              type:        "heartbeat",
              framework:   "solid_queue",
              language:    "ruby",
              sdk_version: TraceStax::VERSION,
              timestamp:   Time.now.utc.iso8601,
              worker: {
                key:         worker_key,
                hostname:    Socket.gethostname,
                pid:         Process.pid,
                queues:      queues,
                concurrency: concurrency
              }
            }
            directives = send_heartbeat_sync(payload)
            if directives
              if directives["pause_ingest"]
                pum = directives["pause_until_ms"]
                set_pause_until(pum) if pum
              end
              (directives["commands"] || []).each do |cmd|
                execute_command(cmd) rescue nil
              end
            end
          rescue StandardError
            # Swallow — heartbeat must never raise into the host process
          end
        end
      end
      thread.abort_on_exception = false
      thread
    end

    # Asynchronously POSTs a queue-depth snapshot to /v1/snapshot.
    # Optional counts default to +nil+ and are omitted from the payload when absent.
    #
    # @param queue_name   [String]  name of the queue being reported
    # @param depth        [Integer] number of jobs currently enqueued
    # @param active_count [Integer, nil] number of actively-running jobs
    # @param failed_count [Integer, nil] number of failed jobs
    def send_snapshot(queue_name:, depth:, active_count: nil, failed_count: nil)
      payload = {
        type:        "snapshot",
        framework:   "solid_queue",
        worker_key:  "#{Socket.gethostname}:#{Process.pid}",
        queues: [{
          name:               queue_name,
          depth:              depth,
          active:             active_count || 0,
          failed:             failed_count || 0,
          throughput_per_min: 0,
        }],
        timestamp: Time.now.utc.iso8601,
      }
      send_event(payload)
    end

    def flush
      reinitialize_if_forked!
      # Check circuit breaker
      return unless circuit_allow?

      batch = []
      batch.push(@queue.pop(true)) while !@queue.empty? && batch.size < config.max_batch_size
      return if batch.empty?

      conn = build_connection

      # All SDKs send a single batched POST — one HTTP request for up to
      # max_batch_size events. This avoids N×HTTP overhead per flush cycle.
      resp = conn.post("/v1/ingest") do |req|
        req.headers["Authorization"] = "Bearer #{config.api_key}"
        req.headers["Content-Type"]  = "application/json"
        req.body = { events: batch }.to_json
      end

      if resp.status == 401
        # Auth failure is permanent misconfiguration, not a transient network issue.
        # Log prominently without penalising the circuit breaker — a bad API key
        # must not open the circuit and suppress all future sends once corrected.
        $stderr.puts("[tracestax] Auth failed (401) — check your API key. #{resp.body.to_s[0, 200]}")
        # Re-queue the batch so events are not silently discarded
        batch.reverse_each { |e| @queue.push(e) rescue nil }
      elsif resp.status >= 400
        record_failure
        # Restore the batch so events aren't permanently lost on transient failures
        batch.reverse_each { |e| @queue.push(e) rescue nil }
      else
        record_success
      end
    rescue StandardError
      record_failure
      # Best-effort restore on unexpected errors
      batch.reverse_each { |e| @queue.push(e) rescue nil } if defined?(batch) && batch
    rescue ThreadError
      # Queue empty during pop
    end

    def shutdown(timeout: 5)
      @mutex.synchronize { @running = false }
      # Wake flush_loop immediately so it performs a final flush and exits.
      # Using a ConditionVariable avoids Thread#kill, which is unsafe when the
      # thread holds @mutex (can permanently poison the lock).
      @shutdown_mutex.synchronize { @shutdown_cv.signal }
      unless @thread&.join(timeout)
        $stderr.puts("[tracestax] shutdown flush timed out after #{timeout}s, dropping remaining events")
        # Do NOT kill the thread — it will exit naturally once the HTTP timeout fires.
      end
    end

    private

    # ── Fork safety ────────────────────────────────────────────────
    #
    # Prefork servers (Unicorn, Puma cluster mode) call fork(2) after the app
    # has booted. Ruby does NOT copy threads into the child — only the calling
    # thread survives. Any mutex that was locked by a now-dead thread is
    # permanently poisoned in the child; acquiring it will deadlock forever.
    #
    # We detect the fork by comparing Process.pid against the PID recorded at
    # initialisation (and after each reinitialisation). On mismatch we replace
    # all mutexes and CVs wholesale — never unlock or acquire the inherited ones
    # — and respawn the daemon thread.
    #
    # This pattern is used by Sidekiq, Puma, and the official redis-client gem.
    # The PID read/write is safe under MRI's GIL: Fixnum ivar assignment is
    # atomic, and this method is only called from the main thread (or from the
    # new daemon thread after reinit, which holds a fresh mutex).
    def reinitialize_if_forked!
      return if Process.pid == @pid

      # Replace every primitive that could be locked by the dead daemon thread.
      # Do NOT call @mutex.unlock or @mutex.synchronize — the lock state is
      # unknown and touching it risks deadlock.
      @mutex          = Mutex.new
      @shutdown_mutex = Mutex.new
      @shutdown_cv    = ConditionVariable.new

      # Pre-fork events belong to the parent worker; discard them.
      # (Attempting to drain the inherited Queue is unsafe because its internal
      # mutex may also be poisoned.)
      @queue = Queue.new

      # Reset all mutable state so the child starts clean.
      @running                = false
      @dropped_events         = 0
      @consecutive_failures   = 0
      @circuit_state          = :closed
      @circuit_opened_at      = nil
      @current_flush_interval = nil
      @pause_until            = nil
      @pid                    = Process.pid

      start
    rescue StandardError
      # Reinitialization must never crash the child process.
    end

    def config
      TraceStax.configuration
    end

    def flush_loop
      loop do
        interval = @mutex.synchronize { @current_flush_interval || config&.flush_interval || 5 }
        # Wait for the interval or an early wakeup from shutdown. Using a
        # ConditionVariable instead of sleep(interval) means shutdown can
        # interrupt the wait immediately without needing Thread#kill.
        @shutdown_mutex.synchronize { @shutdown_cv.wait(@shutdown_mutex, interval) }
        flush rescue nil  # daemon thread must never die — swallow all errors
        break unless @running
      end
    end

    # ── Circuit breaker ────────────────────────────────────────────

    def circuit_allow?
      @mutex.synchronize do
        # Honour backpressure pause
        if @pause_until && Time.now < @pause_until
          return false
        end
        @pause_until = nil

        if @circuit_state == :open
          elapsed = [0, Time.now - @circuit_opened_at].max
          if elapsed < CIRCUIT_COOLDOWN_SECS
            return false
          end
          @circuit_state = :half_open
        end
        true
      end
    end

    def record_success
      @mutex.synchronize do
        @consecutive_failures   = 0
        @circuit_state          = :closed
        @circuit_opened_at      = nil
        base = config&.flush_interval || 5
        @current_flush_interval = [base, (@current_flush_interval || base) / 2.0].max
      end
    end

    def record_failure
      @mutex.synchronize do
        @consecutive_failures   += 1
        base                    = config&.flush_interval || 5
        @current_flush_interval = [MAX_FLUSH_INTERVAL, (@current_flush_interval || base) * 2].min

        if @consecutive_failures >= CIRCUIT_OPEN_THRESHOLD && @circuit_state == :closed
          @circuit_state     = :open
          @circuit_opened_at = Time.now
          $stderr.puts("[tracestax] TraceStax unreachable, circuit open, events dropped")
        elsif @circuit_state == :half_open
          @circuit_state     = :open
          @circuit_opened_at = Time.now
        end
      end
    end

    # ── HTTP ───────────────────────────────────────────────────────

    def build_connection
      Faraday.new(url: config.endpoint) do |f|
        f.options.open_timeout = 5
        f.options.timeout      = 10
        f.request :json
        f.adapter Faraday.default_adapter
      end
    end

    def post_for_json(path, body)
      conn = build_connection
      resp = conn.post(path) do |req|
        req.headers["Authorization"] = "Bearer #{config.api_key}"
        req.headers["Content-Type"]  = "application/json"
        req.body = body.to_json
      end

      if resp.headers["X-Retry-After"]
        secs = resp.headers["X-Retry-After"].to_f
        set_pause_until((Time.now.to_f + secs) * 1000) if secs > 0
      end

      if resp.status == 401
        # Auth failure is permanent misconfiguration, not a transient network issue.
        # Log prominently without penalising the circuit breaker.
        $stderr.puts("[tracestax] Auth failed (401) — check your API key. #{resp.body.to_s[0, 200]}")
        return nil
      end

      if resp.status >= 400
        record_failure
        return nil
      end

      # Cap response body at 1 MB to prevent a runaway or misconfigured server
      # from buffering unbounded memory inside the SDK.
      body_text = resp.body.to_s
      if body_text.bytesize > 1024 * 1024
        $stderr.puts("[tracestax] Ingest response truncated — exceeded 1 MB size limit")
        body_text = "{}"
      end

      record_success
      JSON.parse(body_text)
    rescue StandardError
      record_failure
      nil
    end

    # ── Thread dump ────────────────────────────────────────────────

    def worker_key_for_dump
      "#{Socket.gethostname}:#{Process.pid}"
    end

    def capture_thread_dump
      lines = ["=== TraceStax Ruby Thread Dump ===",
               "PID: #{Process.pid}",
               "Timestamp: #{Time.now.utc.iso8601}",
               ""]
      Thread.list.each do |t|
        lines << "Thread: #{t.object_id} (status=#{t.status})"
        bt = t.backtrace || []
        lines.concat(bt.map { |l| "  #{l}" })
        lines << ""
      end
      lines.join("\n")[0, 500_000]
    end
  end
end
