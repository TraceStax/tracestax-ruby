# frozen_string_literal: true

module TraceStax
  class Configuration
    attr_accessor :api_key, :endpoint, :flush_interval, :max_batch_size, :enabled, :dry_run

    def initialize
      @endpoint = "https://ingest.tracestax.com"
      @flush_interval = 5.0
      @max_batch_size = 100
      @enabled = ENV["TRACESTAX_ENABLED"] != "false"
      @dry_run = ENV["TRACESTAX_DRY_RUN"] == "true"
    end

    def validate!
      return unless @enabled && !@dry_run

      raise Error, "api_key is required" if api_key.nil? || api_key.empty?
    end
  end
end
