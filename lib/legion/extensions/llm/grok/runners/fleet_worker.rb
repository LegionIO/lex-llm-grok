# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/grok'

module Legion
  module Extensions
    module Llm
      module Grok
        module Runners
          # Delivers a fleet envelope to the shared exact-execution responder.
          module FleetWorker
            include Legion::Extensions::Helpers::Lex

            def handle_fleet_request(**message)
              payload = message.key?(:value) ? message[:value] : message.except(:delivery, :properties)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload, provider_family: :grok,
                registry: Legion::Extensions::Llm::Inventory::Registry,
                delivery: message[:delivery], properties: message[:properties]
              )
            end
          end
        end
      end
    end
  end
end
