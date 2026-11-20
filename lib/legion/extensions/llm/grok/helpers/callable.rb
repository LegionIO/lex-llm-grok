# frozen_string_literal: true

require 'legion/extensions/llm/grok/provider'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/routing/provider_outcome'

module Legion
  module Extensions
    module Llm
      module Grok
        module Helpers
          # Per-instance callable stored behind an Inventory callable handle.
          class Callable
            COMPLETION_KEYS = %i[tools schema thinking tool_prefs headers].freeze

            def initialize(instance_cfg:)
              @instance_cfg = instance_cfg
              @provider = nil
              @disconnected = false
            end

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @provider = nil
            end

            def chat(messages, model:, **options)
              ensure_connected!
              provider.enforce_canonical_messages!(messages)
              named, params = split_options(options)
              provider.chat(messages, model: model, params: canonical_params(params), **named)
            end

            def stream_chat(messages, model:, **options, &)
              ensure_connected!
              provider.enforce_canonical_messages!(messages)
              named, params = split_options(options)
              provider.stream_chat(messages, model: model, params: canonical_params(params), **named, &)
            end

            def image(prompt:, model:, size:, **)
              ensure_connected!
              provider.image(prompt: prompt, model: model, size: size, **)
            end

            def count_tokens(messages:, model:, **)
              ensure_connected!
              provider.count_tokens(messages: messages, model: model, **)
            end

            def normalize_dispatch_error(error:)
              kind = if error.is_a?(Legion::Extensions::Llm::Inventory::Errors::CallableDisposedError)
                       :instance_unavailable
                     else
                       Legion::Extensions::Llm::Routing::ProviderOutcome.kind_for(error)
                     end
              reason = error.class.name
              reason = 'UnknownError' if reason.nil? || reason.empty?
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: kind, reason: reason)
            end

            private

            def ensure_connected!
              return unless @disconnected

              raise Legion::Extensions::Llm::Inventory::Errors::CallableDisposedError,
                    'Grok callable is disconnected'
            end

            def provider
              @provider ||= Legion::Extensions::Llm::Grok::Provider.new(@instance_cfg)
            end

            def split_options(options)
              named = options.slice(*COMPLETION_KEYS)
              extra = options.except(*COMPLETION_KEYS)
              supplied = extra.delete(:params)
              params = case supplied
                       when nil then {}
                       when Hash then supplied
                       when Legion::Extensions::Llm::Canonical::Params then supplied.to_h
                       else raise ArgumentError, "Grok params must be Canonical::Params or Hash, got #{supplied.class}"
                       end
              params = params.merge(extra)
              [named, params]
            end

            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end
          end
        end
      end
    end
  end
end
