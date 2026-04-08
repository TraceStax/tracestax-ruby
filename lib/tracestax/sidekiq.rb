# frozen_string_literal: true

require_relative "sidekiq/version"
require_relative "sidekiq/configuration"
require_relative "sidekiq/client"
require_relative "sidekiq/server_middleware"
require_relative "sidekiq/heartbeat_poller"

module TraceStax
  module Sidekiq
    class Error < StandardError; end

    class << self
      attr_accessor :configuration

      # Configure the TraceStax Sidekiq integration.
      #
      #   TraceStax::Sidekiq.configure do |config|
      #     config.api_key = ENV["TRACESTAX_API_KEY"]
      #   end
      def configure
        self.configuration ||= Configuration.new
        yield(configuration)
        configuration.validate!
        Client.instance.start
      end

      def client
        Client.instance
      end

      # Install TraceStax into the Sidekiq server middleware chain and start the
      # heartbeat poller.  Called automatically when you use `install!`; safe to
      # call more than once.
      def install!
        ::Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.prepend TraceStax::Sidekiq::ServerMiddleware
          end
        end

        HeartbeatPoller.start
      end
    end
  end
end
