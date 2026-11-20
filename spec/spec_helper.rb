# frozen_string_literal: true

require 'bundler/setup'
require 'logger'
require 'stringio'
require 'legion/extensions/llm'
require 'legion/settings'
require 'legion/logging'

# The full daemon injects this mixin. Standalone provider specs use the same
# settings and logging helpers without loading the daemon actor runtime.
module Legion
  module Extensions
    module Helpers
      module Lex
        include Legion::Logging::Helper
        include Legion::Settings::Helper

        def self.included(base)
          base.extend(base) if base.instance_of?(Module) && !base.instance_of?(Class)
        end
      end
    end
  end
end

require 'legion/extensions/llm/grok'
require 'legion/extensions/llm/grok/runners/discovery'

null_logger = Logger.new(StringIO.new)
Legion::Logging.instance_variable_set(:@log, null_logger)

RSpec.configure do |config|
  config.order = :random
end
