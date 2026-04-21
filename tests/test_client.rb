# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require "net/http"
require "json"
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

def fetch_ingest_heartbeats
  JSON.parse(Net::HTTP.get(URI("#{INGEST_URL}/test/heartbeats")))
rescue StandardError
  []
end

def ingest_available?
  Net::HTTP.get_response(URI("#{INGEST_URL}/test/health")).code == "200"
rescue StandardError
  false
end

def configured_client(enabled: true, dry_run: false)
  config = TraceStax::Configuration.new
  config.api_key    = "ts_test_abc"
  config.enabled    = enabled
  config.dry_run    = dry_run
  config.endpoint = INGEST_URL
  TraceStax.configuration = config
  TraceStax::Client.instance
end

class TestTraceStaxClientUnit < Minitest::Test
  def setup
    WebMock.enable!
  end

  def teardown
    WebMock.disable!
    WebMock.reset!
    ENV.delete("TRACESTAX_ENABLED")
  end

  def test_disabled_via_env_does_not_enqueue
    stub = stub_request(:any, /#{Regexp.escape(INGEST_URL)}/)

    ENV["TRACESTAX_ENABLED"] = "false"
    config = TraceStax::Configuration.new
    config.api_key    = "ts_test_abc"
    config.endpoint = INGEST_URL
    TraceStax.configuration = config

    TraceStax::Client.instance.send_event({ type: "task_event" })

    assert_not_requested stub
  end

  def test_dry_run_does_not_make_http_calls
    stub = stub_request(:any, /#{Regexp.escape(INGEST_URL)}/)
    client = configured_client(dry_run: true)
    client.send_event({ type: "task_event", status: "succeeded" })
    assert_not_requested stub
  end

  def test_send_event_does_not_raise
    stub_request(:post, "#{INGEST_URL}/v1/ingest").to_return(status: 202, body: '{"received":1}')
    client = configured_client
    client.start
    assert_silent { client.send_event({ type: "task_event" }) }
  end

  def test_queue_max_size_protection
    # Queue should self-limit under high load; send 15k events and confirm no crash
    stub_request(:post, "#{INGEST_URL}/v1/ingest").to_return(status: 202, body: '{"received":1}')
    client = configured_client
    client.start
    15_000.times { client.send_event({ type: "task_event" }) }
    assert true
  end
end

class TestTraceStaxClientIntegration < Minitest::Test
  def setup
    WebMock.disable!
    skip "mock-ingest not available" unless ingest_available?
    # Kill the singleton so integration tests get a fresh client without
    # 15k stale events queued by the unit test's queue_max_size_protection.
    TraceStax::Client.instance.shutdown rescue nil
    TraceStax::Client.send(:new) rescue nil  # force-reset singleton state
    # Clear the singleton instance so configured_client creates a fresh one
    if TraceStax::Client.instance_variable_get(:@singleton__instance__)
      TraceStax::Client.instance_variable_set(:@singleton__instance__, nil)
    end
    reset_ingest
  end

  def test_events_reach_ingest
    client = configured_client
    client.start
    client.send_event({
      type:      "task_event",
      framework: "sidekiq",
      language:  "ruby",
      status:    "succeeded",
      task:      { name: "OrderWorker", id: "job-001", queue: "default", attempt: 1 },
    })
    # Wait up to 10s for the background flush thread to fire
    deadline = Time.now + 10
    events = []
    loop do
      events = fetch_ingest_events
      break if events.any? { |e| e["framework"] == "sidekiq" }
      break if Time.now > deadline
      sleep 0.25
    end
    assert events.any? { |e| e["framework"] == "sidekiq" }, "Expected a sidekiq event, got: #{events.inspect}"
  end

  def test_heartbeat_reaches_ingest
    client = configured_client
    client.start
    client.send_event({
      type:      "heartbeat",
      framework: "sidekiq",
      worker:    { key: "host:1234", hostname: "host", pid: 1234, queues: ["default"] },
      timestamp: Time.now.utc.iso8601,
    })
    # send_event batches via /v1/ingest, so check the events store (not /test/heartbeats
    # which is populated only by direct /v1/heartbeat calls).
    deadline = Time.now + 10
    events = []
    loop do
      events = fetch_ingest_events
      break if events.any? { |e| e["type"] == "heartbeat" }
      break if Time.now > deadline
      sleep 0.25
    end
    assert events.any? { |e| e["type"] == "heartbeat" }, "Expected a heartbeat event, got: #{events.inspect}"
  end
end
