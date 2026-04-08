# frozen_string_literal: true

require_relative "tracestax/client"
require_relative "tracestax/configuration"
require_relative "tracestax/version"

# Framework integrations are NOT auto-required — load only what you need:
#
#   require "tracestax/sidekiq"       # Sidekiq 6.x / 7.x
#   require "tracestax/solid_queue"   # Solid Queue (Rails 8)
#   require "tracestax/resque"        # Resque 2.x
#   require "tracestax/delayed_job"   # Delayed::Job 4.x
#   require "tracestax/good_job"      # Good Job 3.x+

module TraceStax
  class Error < StandardError; end

  class << self
    attr_accessor :configuration

    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
      configuration.validate!
      Client.instance.start
    end

    def client
      Client.instance
    end
  end
end
