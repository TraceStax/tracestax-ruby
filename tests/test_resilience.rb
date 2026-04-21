# frozen_string_literal: true

# Resilience tests for TraceStax::Client.
#
# These tests guard the most critical production guarantee: the SDK must NEVER
# crash, block, or raise into the host application — even when the ingest server
# is down, slow, or returning errors.
#
# Scenarios covered:
#   - enabled=false / dry_run=true are complete no-ops
#   - send_event never raises regardless of server state
#   - Circuit breaker: CLOSED → OPEN after 3 failures, events dropped silently
#   - Circuit breaker: OPEN → HALF_OPEN after cooldown, resets to CLOSED on success
#   - Circuit breaker: HALF_OPEN → OPEN again if probe fails
#   - Queue memory protection: capped at 10K events
#   - X-Retry-After header pauses flush

require "minitest/autorun"
require "webmock/minitest"
require "json"
require_relative "../lib/tracestax"

RESILIENCE_INGEST_URL = "http://ingest.tracestax.test".freeze

# ── Helper ────────────────────────────────────────────────────────────────────

# Build a fresh configuration and return the singleton client with a clean slate.
# The Ruby client is a Singleton, so we reset all mutable state between tests.
def resilience_client(url: RESILIENCE_INGEST_URL, enabled: true, dry_run: false, flush_interval: 60, max_batch_size: 10)
  config = TraceStax::Configuration.new
  config.api_key          = "ts_test_abc"
  config.enabled          = enabled
  config.dry_run          = dry_run
  config.endpoint         = url
  config.flush_interval   = flush_interval
  config.max_batch_size   = max_batch_size
  TraceStax.configuration = config

  client = TraceStax::Client.instance
  # Reset circuit-breaker and queue state
  client.instance_variable_set(:@consecutive_failures,   0)
  client.instance_variable_set(:@circuit_state,          :closed)
  client.instance_variable_set(:@circuit_opened_at,      nil)
  client.instance_variable_set(:@pause_until,            nil)
  client.instance_variable_set(:@current_flush_interval, flush_interval)
  queue = client.instance_variable_get(:@queue)
  queue.size.times { queue.pop(true) rescue nil }

  client
end

# ── enabled=false ─────────────────────────────────────────────────────────────

class TestResilienceDisabled < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
    ENV.delete("TRACESTAX_ENABLED")
  end

  def test_send_event_is_noop
    stub = stub_request(:any, /ingest\.tracestax\.test/)
    client = resilience_client(enabled: false)

    client.send_event({ type: "task_event", status: "succeeded" })

    assert_not_requested stub
    assert_equal 0, client.instance_variable_get(:@queue).size
  end

  def test_send_heartbeat_sync_returns_nil
    client = resilience_client(enabled: false)
    result = client.send_heartbeat_sync({ framework: "sidekiq", worker: {} })
    assert_nil result
  end

  def test_flush_is_noop
    stub = stub_request(:any, /ingest\.tracestax\.test/)
    client = resilience_client(enabled: false)

    client.flush

    assert_not_requested stub
  end

  def test_shutdown_does_not_raise
    client = resilience_client(enabled: false)
    assert_silent { client.shutdown }
  end
end

# ── dry_run=true ──────────────────────────────────────────────────────────────

class TestResilienceDryRun < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def test_send_event_does_not_make_http_calls
    stub = stub_request(:any, /ingest\.tracestax\.test/)
    client = resilience_client(dry_run: true)

    client.send_event({ type: "task_event", status: "succeeded" })

    assert_not_requested stub
  end

  def test_send_heartbeat_sync_returns_nil
    client = resilience_client(dry_run: true)
    result = client.send_heartbeat_sync({ framework: "sidekiq", worker: {} })
    assert_nil result
  end
end

# ── Fire-and-forget guarantees ────────────────────────────────────────────────

class TestResilienceFireAndForget < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def test_send_event_never_raises_with_dead_server
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_raise(Faraday::ConnectionFailed.new("ECONNREFUSED"))

    client = resilience_client

    # Must not raise
    assert_silent do
      20.times { |i| client.send_event({ type: "task_event", id: "job-#{i}" }) }
    end
  end

  def test_flush_never_raises_with_500_response
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 500, body: "internal server error")

    client = resilience_client

    5.times { |i| client.send_event({ type: "task_event", id: "job-#{i}" }) }

    assert_silent { client.flush }
  end

  def test_send_event_from_job_hook_never_raises
    # Simulates an around_perform / after_perform hook
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_raise(Faraday::ConnectionFailed.new("network failure"))

    client   = resilience_client
    job_done = false

    job = proc do
      begin
        job_done = true
      ensure
        # Signal hooks must never raise
        client.send_event({ type: "task_event", status: "succeeded" })
      end
    end

    assert_silent { job.call }
    assert job_done
  end

  def test_original_exception_propagates_when_job_crashes
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_raise(Faraday::ConnectionFailed.new("network failure"))

    client    = resilience_client
    job_error = RuntimeError.new("bad input")

    crashing = proc do
      begin
        raise job_error
      ensure
        client.send_event({ type: "task_event", status: "failed" })
      end
    end

    err = assert_raises(RuntimeError) { crashing.call }
    assert_same job_error, err
  end
end

# ── Circuit breaker ───────────────────────────────────────────────────────────

class TestResilienceCircuitBreaker < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def test_opens_after_3_consecutive_failures
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 503, body: "service unavailable")

    client = resilience_client

    # 3 flush attempts to open the circuit (each enqueue + flush = one HTTP call)
    3.times do |i|
      client.send_event({ type: "task_event", id: "fail-#{i}" })
      client.flush
    end

    assert_equal :open, client.instance_variable_get(:@circuit_state)
    assert client.instance_variable_get(:@consecutive_failures) >= 3
  end

  def test_drops_events_silently_when_open
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 503, body: "service unavailable")

    client = resilience_client

    # Open the circuit
    3.times do |i|
      client.send_event({ type: "task_event", id: "fail-#{i}" })
      client.flush
    end

    WebMock.reset!
    drop_stub = stub_request(:any, /ingest\.tracestax\.test/)

    # These must be silently dropped — no HTTP calls made
    10.times { |i| client.send_event({ type: "task_event", id: "drop-#{i}" }) }
    client.flush

    assert_not_requested drop_stub
  end

  def test_transitions_open_to_half_open_after_cooldown
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 503, body: "service unavailable")

    client = resilience_client

    # Open the circuit
    3.times do |i|
      client.send_event({ type: "task_event", id: "fail-#{i}" })
      client.flush
    end
    assert_equal :open, client.instance_variable_get(:@circuit_state)

    # Simulate cooldown elapsed
    client.instance_variable_set(:@circuit_opened_at, Time.now - 31)

    # circuit_allow? should now transition to :half_open
    result = client.send(:circuit_allow?)
    assert result, "Expected circuit_allow? to return true after cooldown"
    assert_equal :half_open, client.instance_variable_get(:@circuit_state)
  end

  def test_resets_to_closed_on_successful_probe
    call_count = 0
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return do |_|
        call_count += 1
        if call_count <= 3
          { status: 503, body: "down" }
        else
          { status: 200, body: '{"ok":true}' }
        end
      end

    client = resilience_client

    # Open the circuit
    3.times do |i|
      client.send_event({ type: "task_event", id: "fail-#{i}" })
      client.flush
    end
    assert_equal :open, client.instance_variable_get(:@circuit_state)

    # Simulate cooldown elapsed
    client.instance_variable_set(:@circuit_opened_at, Time.now - 31)

    # Probe: should succeed and close the circuit
    client.send_event({ type: "task_event", id: "probe" })
    client.flush

    assert_equal :closed, client.instance_variable_get(:@circuit_state)
    assert_equal 0, client.instance_variable_get(:@consecutive_failures)
  end

  def test_returns_to_open_if_half_open_probe_fails
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 503, body: "still down")

    client = resilience_client

    # Put directly in HALF_OPEN state
    client.instance_variable_set(:@circuit_state, :half_open)
    client.instance_variable_set(:@consecutive_failures, 3)
    client.instance_variable_set(:@circuit_opened_at, Time.now)

    # Probe fails → should re-open
    client.send_event({ type: "task_event", id: "probe" })
    client.flush

    assert_equal :open, client.instance_variable_get(:@circuit_state)
  end
end

# ── Queue memory protection ───────────────────────────────────────────────────

class TestResilienceQueueMemory < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def test_queue_capped_at_10k_events
    stub_request(:any, /ingest\.tracestax\.test/)

    client = resilience_client

    # Queue 11K events — the SDK should trim to 5K when it exceeds 10K
    11_000.times { |i| client.send_event({ type: "task_event", id: "e#{i}" }) }

    assert_operator client.instance_variable_get(:@queue).size, :<=, 10_000
  end

  def test_queue_does_not_raise_under_high_load
    stub_request(:any, /ingest\.tracestax\.test/)

    client = resilience_client

    assert_silent do
      15_000.times { |i| client.send_event({ type: "task_event", id: "e#{i}" }) }
    end
  end
end

# ── X-Retry-After backpressure ────────────────────────────────────────────────

class TestResilienceRetryAfter < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def test_pauses_flush_for_retry_after_duration
    call_count = 0
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return do |_|
        call_count += 1
        { status: 429, headers: { "X-Retry-After" => "10" }, body: "rate limited" }
      end

    client = resilience_client

    client.send_event({ type: "task_event", id: "rate-1" })
    client.flush
    assert_equal 1, call_count

    # Within the 10s window, flush must be a no-op
    client.send_event({ type: "task_event", id: "rate-2" })
    client.flush
    assert_equal 1, call_count  # still 1 — paused

    # Simulate expiry
    client.instance_variable_set(:@pause_until, Time.now - 1)

    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 200, body: '{"ok":true}')

    client.flush
    assert call_count >= 2  # resumed and flushed
  end
end

# ── Stats API ─────────────────────────────────────────────────────────────────

class TestResilienceStats < Minitest::Test
  def setup
    WebMock.enable!
    stub_request(:any, /ingest\.tracestax\.test/)
      .to_return(status: 200, body: '{"ok":true}')
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  def test_stats_returns_hash_with_expected_keys
    client = resilience_client
    s = client.stats
    assert_includes s, :queue_size
    assert_includes s, :dropped_events
    assert_includes s, :circuit_state
    assert_includes s, :consecutive_failures
  end

  def test_stats_initial_circuit_state_is_closed
    client = resilience_client
    assert_equal :closed, client.stats[:circuit_state]
  end

  def test_stats_dropped_events_increments_on_overflow
    client = resilience_client
    11_000.times { |i| client.send_event({ type: "task_event", id: "e#{i}" }) }
    assert client.stats[:dropped_events] > 0, "dropped_events must be > 0 after overflow"
  end
end

# ── Shutdown timeout ──────────────────────────────────────────────────────────

class TestResilienceShutdownTimeout < Minitest::Test
  def test_shutdown_completes_within_timeout_even_with_dead_server
    WebMock.disable!  # let the actual TCP connect fail fast

    client = resilience_client(url: "http://127.0.0.1:19999") # dead port
    client.send_event({ type: "task_event", id: "shutdown-1" })

    started = Time.now
    # timeout of 2s — should return well before 5s even if server is dead
    client.shutdown(timeout: 2)
    elapsed = Time.now - started

    assert elapsed < 5.0, "shutdown took #{elapsed.round(2)}s, expected < 5s"
  ensure
    WebMock.enable!
  end
end

# ── Batch HTTP (H3 from audit) ────────────────────────────────────────────────

class TestResilienceBatchHttp < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  # Before the fix, flush() sent each event as a separate HTTP request.
  # After the fix, all events in a batch are sent as ONE POST {"events":[...]}.
  def test_flush_sends_all_events_in_a_single_batch_request
    request_count = 0
    received_bodies = []

    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return do |request|
        request_count += 1
        received_bodies << JSON.parse(request.body)
        { status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" } }
      end

    client = resilience_client(max_batch_size: 50)
    5.times { |i| client.send_event({ type: "task_event", id: "e#{i}", status: "started" }) }

    client.flush

    assert_equal 1, request_count,
      "Expected exactly 1 HTTP request for 5 events (batched), got #{request_count}"
    assert_equal 1, received_bodies.size
    body = received_bodies.first
    assert body.key?("events"), "Batch payload must have an 'events' key"
    assert_equal 5, body["events"].size, "All 5 events must be in the single batch request"
  end

  def test_flush_restores_events_on_server_error
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 503, body: "unavailable")

    client = resilience_client(max_batch_size: 10)
    3.times { |i| client.send_event({ type: "task_event", id: "e#{i}" }) }

    before_size = client.instance_variable_get(:@queue).size
    assert_equal 3, before_size

    client.flush

    # After a failed flush the events should be restored to the queue
    after_size = client.instance_variable_get(:@queue).size
    assert after_size > 0, "Events must be restored to queue after failed flush (got #{after_size})"
  end
end

# ── Serialization safety ──────────────────────────────────────────────────────

class TestSerializationSafety < Minitest::Test
  def setup
    WebMock.disable!
  end

  def teardown
    WebMock.enable!
  end

  def test_send_event_dry_run_non_serializable_payload_does_not_raise
    # An object that raises on .to_json should be swallowed, not propagated
    client = resilience_client(dry_run: true)

    bad_payload = Object.new
    def bad_payload.to_json(*_args)
      raise JSON::GeneratorError, "cannot serialize"
    end

    # If send_event raises, the test will error — that IS the assertion
    client.send_event(bad_payload)
    assert true, "send_event must not raise on non-serializable payload"
  end

  def test_send_event_dry_run_closed_stdout_does_not_raise
    # $stdout.puts raises IOError when stdout is closed (e.g. daemonized processes)
    client = resilience_client(dry_run: true)

    original_stdout = $stdout
    begin
      $stdout = StringIO.new.tap(&:close)
      # If send_event raises, the test will error — that IS the assertion
      client.send_event({ type: "task_event", id: "test" })
      assert true, "send_event must not raise when stdout is closed"
    ensure
      $stdout = original_stdout
    end
  end
end

# ── Cooperative shutdown ────────────────────────────────────────────────────────

class TestResilienceCooperativeShutdown < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
  end

  # Verify that shutdown completes within the deadline even when the flush thread
  # holds @mutex. The cooperative ConditionVariable approach replaced Thread#kill,
  # which was unsafe: killing a thread while it holds a Mutex permanently poisons
  # the lock, causing deadlocks on the next acquire.
  def test_shutdown_completes_within_timeout_without_deadlock
    # Simulate a server that hangs for 30 seconds (longer than shutdown timeout)
    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return do |_request|
        sleep(30)
        { status: 200, body: '{"ok":true}' }
      end

    client = resilience_client(flush_interval: 1)
    client.instance_variable_set(:@running, true)

    # Queue an event to ensure flush tries an HTTP call (which will hang)
    client.send_event({ type: "task_event", id: "slow-flush" })

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.shutdown(timeout: 2)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    assert elapsed < 5.0,
           "shutdown took #{elapsed.round(2)}s — expected to return within 5s even with hung server"
  end

  # Verify that calling shutdown twice (e.g. at_exit + explicit call) is safe.
  def test_shutdown_is_idempotent
    stub_request(:any, /ingest\.tracestax\.test/)
      .to_return(status: 200, body: '{"ok":true}')

    client = resilience_client
    client.shutdown(timeout: 2)

    # Second shutdown must not raise or deadlock
    assert_silent { client.shutdown(timeout: 1) }
  end
end

# ── Large payload size guard (2B) ─────────────────────────────────────────────

class TestLargePayloadGuard < Minitest::Test

  def setup
    super
    WebMock.disable_net_connect!
    TraceStax.configure do |c|
      c.api_key  = "ts_test"
      c.enabled  = true
      c.dry_run  = false
      c.endpoint = "https://ingest.tracestax.test"
    end
  end

  def test_oversized_payload_dropped_without_raising
    client = TraceStax::Client.instance
    big_payload = { task: "big", data: "x" * (600 * 1024) }
    client.send_event(big_payload)
    assert_equal 0, client.instance_variable_get(:@queue).size,
                 "Oversized event must not be enqueued"
  end

  def test_non_serializable_payload_dropped_without_raising
    client = TraceStax::Client.instance
    # BasicObject does not respond to to_json — .to_json call will raise
    bad_payload = { task: "bad", obj: BasicObject.new }
    client.send_event(bad_payload)
    assert_equal 0, client.instance_variable_get(:@queue).size,
                 "Non-serializable event must not be enqueued"
  end

  def test_normal_payload_accepted_after_oversized_drop
    client = TraceStax::Client.instance
    q = client.instance_variable_get(:@queue)
    client.send_event({ data: "x" * (600 * 1024) })  # dropped
    client.send_event({ task: "small" })               # must be accepted
    assert_equal 1, q.size, "Normal event after dropped oversized must still be queued"
  end
end

# ── Circuit breaker clock skew (2D) ──────────────────────────────────────────

class TestClockSkewResilience < Minitest::Test

  def setup
    super
    WebMock.disable_net_connect!
    stub_request(:post, /ingest\.tracestax\.test/)
      .to_return(status: 503, body: '{"error":"down"}')
    TraceStax.configure do |c|
      c.api_key  = "ts_test"
      c.enabled  = true
      c.endpoint = "https://ingest.tracestax.test"
    end
  end

  def test_backward_clock_does_not_freeze_circuit_open
    client = TraceStax::Client.instance

    # Open the circuit with 3 failures
    3.times { client.send_event({ task: "fail" }); client.flush }
    assert_equal :open, client.instance_variable_get(:@circuit_state)

    # Simulate backward clock: set opened_at to the future
    client.instance_variable_set(:@circuit_opened_at, Time.now + 60)
    # [0, elapsed].max clamps to 0 → still OPEN (< 30 s), not stuck forever
    refute client.send(:circuit_allow?), "Circuit must remain OPEN after backward clock jump"

    # Push opened_at 31 s into the past — cooldown expired, circuit must probe
    client.instance_variable_set(:@circuit_opened_at, Time.now - 31)
    assert client.send(:circuit_allow?), "Circuit must allow probe after cooldown"
    assert_equal :half_open, client.instance_variable_get(:@circuit_state)
  end
end

# ── Fork safety ───────────────────────────────────────────────────────────────

class TestForkSafety < Minitest::Test
  def setup
    WebMock.disable_net_connect!
    WebMock.reset!
  end

  def teardown
    WebMock.reset!
  end

  # Fast path: spoof @pid to simulate a fork without actually forking.
  # Verifies that reinitialize_if_forked! detects the PID mismatch and
  # replaces mutexes/queue/state without deadlocking.
  def test_pid_spoof_triggers_reinitialization
    client = resilience_client
    client.start

    # Open the circuit so we can verify it was reset
    client.instance_variable_set(:@circuit_state, :open)
    client.instance_variable_set(:@consecutive_failures, 5)

    # Spoof PID to simulate being in a forked child
    original_pid = client.instance_variable_get(:@pid)
    client.instance_variable_set(:@pid, original_pid + 1)

    # Must not deadlock and must not raise
    assert_silent { client.send_event({ type: "task_event", id: "fork-test" }) }

    # After reinitialization the PID must match the real process PID
    assert_equal Process.pid, client.instance_variable_get(:@pid)

    # Circuit state must be reset to closed
    assert_equal :closed, client.instance_variable_get(:@circuit_state)
    assert_equal 0, client.instance_variable_get(:@consecutive_failures)
  end

  # Real fork test: actually forks the process and verifies the child can
  # call send_event and flush without deadlocking.
  # Skipped on JRuby / TruffleRuby where fork is not supported.
  def test_child_process_can_send_after_fork
    skip "fork not supported on this Ruby runtime" unless Process.respond_to?(:fork)

    stub_request(:post, "#{RESILIENCE_INGEST_URL}/v1/ingest")
      .to_return(status: 202, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

    client = resilience_client
    client.start

    rd, wr = IO.pipe

    pid = fork do
      rd.close
      begin
        # In the child, mutexes from the parent may be in an unknown state.
        # reinitialize_if_forked! should handle this transparently.
        client.send_event({ type: "task_event", id: "child-event-1" })
        client.send_event({ type: "task_event", id: "child-event-2" })
        client.flush
        wr.write("ok")
      rescue => e
        wr.write("error: #{e.class}: #{e.message}")
      ensure
        wr.close
        exit!(0)
      end
    end

    wr.close
    result = rd.read
    Process.waitpid(pid)

    assert_equal "ok", result, "Child process must be able to send and flush without error"
  end
end
