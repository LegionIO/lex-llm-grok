# frozen_string_literal: true

require 'legion/extensions/llm/grok'

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  Legion::Extensions::Llm::Grok.handle_exception(
    e, level: :warn, operation: 'grok.actor.fleet_worker.load_subscription'
  )
end

return unless defined?(Legion::Extensions::Actors::Subscription)

require 'legion/extensions/llm/grok/runners/fleet_worker'
require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Llm
      module Grok
        module Actor
          # Opt-in fleet subscription for authenticated Grok instances.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            include Legion::Extensions::Helpers::Lex

            def runner_class = Legion::Extensions::Llm::Grok::Runners::FleetWorker
            def runner_function = 'handle_fleet_request'
            def use_runner? = false

            def enabled?
              instances = Legion::Extensions::Llm::Grok.discover_instances
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(instances)
            end
          end
        end
      end
    end
  end
end
