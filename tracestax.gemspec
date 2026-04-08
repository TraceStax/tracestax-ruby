Gem::Specification.new do |spec|
  spec.name          = "tracestax"
  spec.version       = "0.1.0"
  spec.authors       = ["TraceStax"]
  spec.email         = ["support@tracestax.com"]

  spec.summary       = "TraceStax monitoring for Ruby background job frameworks"
  spec.description   = "Worker intelligence and observability for Ruby background jobs. " \
                       "Supports Sidekiq (6.x/7.x), Solid Queue (Rails 8), Resque, Delayed::Job, and Good Job. " \
                       "Automatic instrumentation of job lifecycle, queue health, and anomaly detection."
  spec.homepage      = "https://tracestax.com"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.add_dependency "faraday", ">= 2.0"

  # Framework integrations are optional — only load what your app uses:
  #   require "tracestax/sidekiq"      # for Sidekiq
  #   require "tracestax/solid_queue"  # for Solid Queue (Rails 8)
  #   require "tracestax/resque"       # for Resque
  #   require "tracestax/delayed_job"  # for Delayed::Job
  #   require "tracestax/good_job"     # for Good Job
  spec.add_development_dependency "sidekiq", "~> 7.0"
  spec.add_development_dependency "solid_queue", ">= 0.3"
  spec.add_development_dependency "resque", ">= 2.0"
  spec.add_development_dependency "delayed_job", ">= 4.1"
  spec.add_development_dependency "good_job", ">= 3.0"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
end
