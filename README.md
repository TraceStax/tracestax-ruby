# tracestax

TraceStax SDK for Ruby background jobs. Automatically captures task lifecycle events, worker heartbeats, and queue depth snapshots.

Supports **Sidekiq** (6.x / 7.x), **Solid Queue** (Rails 8), **Resque**, **Delayed::Job**, and **Good Job**.

## Installation

Add to your `Gemfile`:

```ruby
gem "tracestax"
```

Then run:

```bash
bundle install
```

## Quickstart - Sidekiq

```ruby
# config/initializers/tracestax.rb
TraceStax.configure do |config|
  config.api_key = ENV["TRACESTAX_API_KEY"]
end

TraceStax::Sidekiq.configure
```

The SDK installs a server middleware that automatically instruments all Sidekiq jobs - no changes to individual workers needed.

## Quickstart - Solid Queue (Rails 8)

```ruby
# config/initializers/tracestax.rb
TraceStax.configure do |config|
  config.api_key = ENV["TRACESTAX_API_KEY"]
end

TraceStax::SolidQueueSubscriber.attach
```

## Quickstart - Resque

```ruby
TraceStax.configure do |config|
  config.api_key = ENV["TRACESTAX_API_KEY"]
end

require "tracestax/resque"
```

## Quickstart - Delayed::Job

```ruby
TraceStax.configure do |config|
  config.api_key = ENV["TRACESTAX_API_KEY"]
end

require "tracestax/delayed_job"
```

## Quickstart - Good Job

```ruby
TraceStax.configure do |config|
  config.api_key = ENV["TRACESTAX_API_KEY"]
end

require "tracestax/good_job"
```

## Configuration

```ruby
TraceStax.configure do |config|
  config.api_key          = ENV["TRACESTAX_API_KEY"]   # Required
  config.endpoint         = "https://ingest.tracestax.com"  # Override ingest endpoint
  config.flush_interval   = 5.0    # Seconds between batch flushes
  config.max_batch_size   = 100    # Max events per HTTP request
  config.heartbeat_interval = 60   # Seconds between worker heartbeats
end
```

## What's Monitored

- Job lifecycle (start, success, failure, retry)
- Worker fleet health (heartbeat, concurrency)
- Queue depth and throughput
- Error fingerprinting and grouping
- Anomaly detection (duration spikes, silence detection)

## Authentication

All requests use your API key as a Bearer token:

```
Authorization: Bearer ts_live_xxx
```

Get your project API key from the TraceStax dashboard under **Project → API Key**.

## License

MIT
