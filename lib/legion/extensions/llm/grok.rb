# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/settings/helper'
require 'legion/logging/helper'
require 'legion/extensions/llm/grok/translator'
require 'legion/extensions/llm/grok/provider'
require 'legion/extensions/llm/grok/helpers/callable'
require 'legion/extensions/llm/grok/actors/discovery'
require 'legion/extensions/llm/grok/version'

module Legion
  module Extensions
    module Llm
      # xAI Grok provider namespace. Only configured, authenticated instances
      # enter the shared discovery and Inventory publication pipeline.
      module Grok
        extend Legion::Logging::Helper
        extend Legion::Settings::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :grok
        API_BASE = 'https://api.x.ai'

        def self.default_settings
          Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: API_BASE,
              tier: :cloud,
              transport: :http,
              credentials: { api_key: nil },
              request_timeout: 900,
              usage: { inference: true, embedding: false, image: true },
              limits: { concurrency: 4 },
              fleet: { enabled: false, respond_to_requests: false, capabilities: %i[chat stream_chat image] }
            }
          )
        end

        def self.provider_class = Legion::Extensions::Llm::Grok::Provider

        def self.discover_instances
          configured = settings[:instances]
          return {} unless configured.is_a?(Hash)

          configured.each_with_object({}) do |(name, raw), instances|
            config = normalize_instance_config(raw)
            next if config[:enabled] == false
            next if config[:grok_api_key].to_s.strip.empty?
            next if config[:grok_api_key].to_s.start_with?('vault://', 'env://')

            instances[name.to_sym] = config
          end
        end

        def self.normalize_instance_config(raw)
          raise ArgumentError, 'Grok instance config must be a Hash' unless raw.is_a?(Hash)

          config = raw.transform_keys(&:to_sym)
          credentials = config.delete(:credentials)
          credentials = credentials.transform_keys(&:to_sym) if credentials.is_a?(Hash)
          config[:grok_api_key] ||= credentials&.[](:api_key)
          config[:grok_api_key] ||= ENV.fetch('XAI_API_KEY', nil)
          config[:grok_api_base] ||= config.delete(:base_url) || config.delete(:endpoint) || API_BASE
          config[:grok_api_base] = Legion::Extensions::Llm::Grok::Provider.normalize_api_base(config[:grok_api_base])
          config[:tier] ||= :cloud
          config
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
