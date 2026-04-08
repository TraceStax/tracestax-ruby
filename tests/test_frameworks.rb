# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "json"
require "socket"
require_relative "../lib/tracestax"

INGEST_URL = ENV.fetch("TRACESTAX_INGEST_URL", "http://localhost:4001")

def reset_ingest
  Net::HTTP.post(URI("#{INGEST_URL}/test/reset"), "")
rescue StandardError
  nil
end

def fetch_ingest_events
  JSON.parse(Net::HTTP.get(URI("#{INGEST_URL}/test/events")))
rescue StandardError
  []
end

def ingest_available?
  Net::HTTP.get_response(URI("#{INGEST_URL}/test/health")).code == "200"
rescue StandardError
  false
end

def wait_for_events(timeout: 10, &predicate)
  deadline = Time.now + timeout
  loop do
    events = fetch_ingest_events
    return events if events.any?(&predicate)
    break if Time.now > deadline
    sleep 0.25
  end
  fetch_ingest_events
end

def configured_client
  # Reset singleton for a clean state
  if TraceStax::Client.instance_variable_get(:@singleton__instance__)
    TraceStax::Client.instance.shutdown rescue nil
    TraceStax::Client.instance_variable_set(:@singleton__instance__, nil)
  end

  config = TraceStax::Configuration.new
  config.api_key = "ts_test_abc"
  config.enabled = true
  config.dry_run = false
  config.endpoint = INGEST_URL
  config.flush_interval = 1.0
  config.max_batch_size = 100
  TraceStax.configuration = config
  client = TraceStax::Client.instance
  client.start
  client
end


# ── Sidekiq simulation ─────────────────────────────────────────────────

class TestSidekiqSimulation < Minitest::Test
  def setup
    skip "mock-ingest not available" unless ingest_available?
    reset_ingest
    @client = configured_client
  end

  def test_sidekiq_task_succeeded
    @client.send_event({
      type:        "task_event",
      framework:   "sidekiq",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "succeeded",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        concurrency: 5,
        queues: ["default", "mailers"]
      },
      task: { name: "OrderWorker", id: "sidekiq-sim-001", queue: "default", attempt: 1 },
      metrics: { duration_ms: 120 }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "sidekiq-sim-001" }
    match = events.select { |e| e.dig("task", "id") == "sidekiq-sim-001" }
    assert match.length >= 1, "Expected at least 1 sidekiq event"
    assert_equal "sidekiq", match[0]["framework"]
    assert_equal "succeeded", match[0]["status"]
    assert_equal 120, match[0].dig("metrics", "duration_ms")
  end

  def test_sidekiq_task_failed_with_error
    @client.send_event({
      type:        "task_event",
      framework:   "sidekiq",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "failed",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        concurrency: 5,
        queues: ["default"]
      },
      task: { name: "PaymentWorker", id: "sidekiq-sim-002", queue: "default", attempt: 3 },
      metrics: { duration_ms: 45 },
      error: { type: "Stripe::CardError", message: "card declined", stack_trace: "worker.rb:10\nbase.rb:20" }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "sidekiq-sim-002" }
    match = events.select { |e| e.dig("task", "id") == "sidekiq-sim-002" }
    assert match.length >= 1
    assert_equal "failed", match[0]["status"]
    assert_equal "Stripe::CardError", match[0].dig("error", "type")
  end
end


# ── Resque simulation ─────────────────────────────────────────────────

class TestResqueSimulation < Minitest::Test
  def setup
    skip "mock-ingest not available" unless ingest_available?
    reset_ingest
    @client = configured_client
  end

  def test_resque_task_succeeded
    @client.send_event({
      type:        "task_event",
      framework:   "resque",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "succeeded",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        queues:   ["default"]
      },
      task: { name: "ImageProcessor", id: "resque-sim-001", queue: "default", attempt: 1 },
      metrics: { duration_ms: 450 }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "resque-sim-001" }
    match = events.select { |e| e.dig("task", "id") == "resque-sim-001" }
    assert match.length >= 1
    assert_equal "resque", match[0]["framework"]
    assert_equal "succeeded", match[0]["status"]
  end

  def test_resque_task_failed
    @client.send_event({
      type:        "task_event",
      framework:   "resque",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "failed",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        queues:   ["high"]
      },
      task: { name: "NotificationSender", id: "resque-sim-002", queue: "high", attempt: 1 },
      metrics: { duration_ms: 12 },
      error: { type: "Redis::TimeoutError", message: "connection timed out" }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "resque-sim-002" }
    match = events.select { |e| e.dig("task", "id") == "resque-sim-002" }
    assert match.length >= 1
    assert_equal "failed", match[0]["status"]
    assert_equal "Redis::TimeoutError", match[0].dig("error", "type")
  end
end


# ── Delayed::Job simulation ───────────────────────────────────────────

class TestDelayedJobSimulation < Minitest::Test
  def setup
    skip "mock-ingest not available" unless ingest_available?
    reset_ingest
    @client = configured_client
  end

  def test_delayed_job_task_succeeded
    @client.send_event({
      type:        "task_event",
      framework:   "delayed_job",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "succeeded",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        queues:   ["default"]
      },
      task: { name: "ReportGenerator", id: "dj-sim-001", queue: "default", attempt: 1 },
      metrics: { duration_ms: 2500 }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "dj-sim-001" }
    match = events.select { |e| e.dig("task", "id") == "dj-sim-001" }
    assert match.length >= 1
    assert_equal "delayed_job", match[0]["framework"]
    assert_equal "succeeded", match[0]["status"]
  end

  def test_delayed_job_task_failed
    @client.send_event({
      type:        "task_event",
      framework:   "delayed_job",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "failed",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        queues:   ["mailers"]
      },
      task: { name: "WelcomeEmailJob", id: "dj-sim-002", queue: "mailers", attempt: 4 },
      metrics: { duration_ms: 300 },
      error: { type: "Net::SMTPAuthenticationError", message: "535 Authentication failed" }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "dj-sim-002" }
    match = events.select { |e| e.dig("task", "id") == "dj-sim-002" }
    assert match.length >= 1
    assert_equal "failed", match[0]["status"]
    assert_equal 4, match[0].dig("task", "attempt")
  end
end


# ── Good Job simulation ──────────────────────────────────────────────

class TestGoodJobSimulation < Minitest::Test
  def setup
    skip "mock-ingest not available" unless ingest_available?
    reset_ingest
    @client = configured_client
  end

  def test_good_job_task_succeeded
    @client.send_event({
      type:        "task_event",
      framework:   "good_job",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "succeeded",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        queues:   ["default"]
      },
      task: { name: "CleanupJob", id: "gj-sim-001", queue: "default", attempt: 1 },
      metrics: { duration_ms: 80 }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "gj-sim-001" }
    match = events.select { |e| e.dig("task", "id") == "gj-sim-001" }
    assert match.length >= 1
    assert_equal "good_job", match[0]["framework"]
    assert_equal "succeeded", match[0]["status"]
  end

  def test_good_job_task_failed
    @client.send_event({
      type:        "task_event",
      framework:   "good_job",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "failed",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        queues:   ["default"]
      },
      task: { name: "AnalyticsJob", id: "gj-sim-002", queue: "default", attempt: 2 },
      metrics: { duration_ms: 15 },
      error: { type: "ActiveRecord::RecordNotFound", message: "Couldn't find User with id=999" }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "gj-sim-002" }
    match = events.select { |e| e.dig("task", "id") == "gj-sim-002" }
    assert match.length >= 1
    assert_equal "failed", match[0]["status"]
    assert_equal "ActiveRecord::RecordNotFound", match[0].dig("error", "type")
  end
end


# ── Solid Queue simulation ───────────────────────────────────────────

class TestSolidQueueSimulation < Minitest::Test
  def setup
    skip "mock-ingest not available" unless ingest_available?
    reset_ingest
    @client = configured_client
  end

  def test_solid_queue_task_succeeded
    @client.send_event({
      type:        "task_event",
      framework:   "solid_queue",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "succeeded",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        concurrency: 3,
        queues: ["default"]
      },
      task: { name: "ImportJob", id: "sq-sim-001", queue: "default", attempt: 1 },
      metrics: { duration_ms: 950 }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "sq-sim-001" }
    match = events.select { |e| e.dig("task", "id") == "sq-sim-001" }
    assert match.length >= 1
    assert_equal "solid_queue", match[0]["framework"]
    assert_equal "succeeded", match[0]["status"]
    assert_equal 950, match[0].dig("metrics", "duration_ms")
  end

  def test_solid_queue_task_failed
    @client.send_event({
      type:        "task_event",
      framework:   "solid_queue",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "failed",
      worker: {
        key:      "#{Socket.gethostname}:#{Process.pid}",
        hostname: Socket.gethostname,
        pid:      Process.pid,
        concurrency: 3,
        queues: ["default"]
      },
      task: { name: "ExportJob", id: "sq-sim-002", queue: "default", attempt: 1 },
      metrics: { duration_ms: 1200 },
      error: { type: "Errno::ENOSPC", message: "No space left on device" }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "sq-sim-002" }
    match = events.select { |e| e.dig("task", "id") == "sq-sim-002" }
    assert match.length >= 1
    assert_equal "failed", match[0]["status"]
    assert_equal "Errno::ENOSPC", match[0].dig("error", "type")
  end
end


# ── Event structure validation ───────────────────────────────────────

class TestEventStructure < Minitest::Test
  REQUIRED_FIELDS = %w[type framework language sdk_version status worker task metrics].freeze
  REQUIRED_WORKER_FIELDS = %w[key hostname pid queues].freeze
  REQUIRED_TASK_FIELDS = %w[name id queue attempt].freeze

  def setup
    skip "mock-ingest not available" unless ingest_available?
    reset_ingest
    @client = configured_client
  end

  def test_full_event_structure
    @client.send_event({
      type:        "task_event",
      framework:   "sidekiq",
      language:    "ruby",
      sdk_version: "0.1.0",
      status:      "succeeded",
      worker: {
        key:      "test:1",
        hostname: "test",
        pid:      1,
        queues:   ["default"]
      },
      task: { name: "StructTest", id: "struct-ruby-001", queue: "default", attempt: 1 },
      metrics: { duration_ms: 42 }
    })

    events = wait_for_events { |e| e.dig("task", "id") == "struct-ruby-001" }
    match = events.select { |e| e.dig("task", "id") == "struct-ruby-001" }
    assert match.length >= 1, "Expected at least 1 event with id struct-ruby-001"
    event = match[0]

    # Top-level required fields
    REQUIRED_FIELDS.each do |field|
      assert event.key?(field), "Missing required field: #{field}"
    end

    # Worker sub-fields
    REQUIRED_WORKER_FIELDS.each do |field|
      assert event["worker"].key?(field), "Missing worker field: #{field}"
    end

    # Task sub-fields
    REQUIRED_TASK_FIELDS.each do |field|
      assert event["task"].key?(field), "Missing task field: #{field}"
    end

    # Metrics
    assert event["metrics"].key?("duration_ms"), "Missing metrics.duration_ms"
  end
end
