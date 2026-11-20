# frozen_string_literal: true

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/grok/helpers/callable'

module Legion
  module Extensions
    module Llm
      module Grok
        module Runners
          # xAI catalog and evidence hooks for the shared Inventory writer.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            def catalog_base_url(instance_cfg:)
              Legion::Extensions::Llm::Grok::Provider.normalize_api_base(instance_cfg.fetch(:grok_api_base))
            end

            def auth_token(instance_cfg:)
              instance_cfg.fetch(:grok_api_key)
            end

            def build_connection(base_url:, instance_cfg:, timeout:, open_timeout:)
              connection = super
              connection.ssl.verify = true if base_url.start_with?('https://')
              connection
            end

            def health_path = '/v1/models'

            def fetch_raw_models(instance_cfg:)
              conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg),
                                      instance_cfg: instance_cfg, timeout: 15, open_timeout: 5)
              all = read_catalog(conn, '/v1/models', :data)
              languages = read_catalog(conn, '/v1/language-models', :models).to_h do |model|
                [model.fetch(:id), model]
              end
              images = read_catalog(conn, '/v1/image-generation-models', :models).to_h do |model|
                [model.fetch(:id), model]
              end
              all.filter_map do |model|
                id = model.fetch(:id)
                if languages.key?(id)
                  model.merge(languages.fetch(id)).merge(kind: :language)
                elsif images.key?(id)
                  model.merge(images.fetch(id)).merge(kind: :image)
                end
              end
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Grok::Helpers::Callable.new(instance_cfg: instance_cfg)
            end

            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              _ = instance_key
              unless model_id == model_data.fetch(:id)
                raise ArgumentError,
                      'Grok model ID disagrees with catalog record'
              end

              image = Legion::Extensions::Llm::Grok::Provider::Capabilities.image_model?(model_data)
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id,
                tier: instance_cfg.fetch(:tier),
                operation_evidence: operation_evidence(image: image, model_data: model_data),
                capability_evidence: capability_evidence(image: image, model_data: model_data),
                context_evidence: value_evidence(model_data[:context_length]),
                max_output_evidence: value_evidence(model_data[:max_output_tokens]),
                embedding_dimensions_evidence: unknown_value,
                model_revision_evidence: string_evidence(model_data[:version]),
                tokenizer_evidence: unknown_value,
                quota_domains: {}, metadata: { catalog_kind: model_data.fetch(:kind).to_s },
                publication_source: :provider_catalog
              )
            end

            private

            def read_catalog(conn, path, field)
              response = conn.get(path)
              unless response.status == 200
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      "#{path} returned HTTP #{response.status}"
              end

              body = Legion::JSON.load(response.body)
              rows = body.fetch(field)
              unless rows.is_a?(Array)
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      "#{path} has no #{field} array"
              end

              rows
            end

            def operation_evidence(image:, model_data:)
              now = Time.now.freeze
              chat = Legion::Extensions::Llm::Grok::Provider::Capabilities.chat?(model_data)
              Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |operation|
                supported = if image then operation == :image
                            else chat && %i[chat stream_chat].include?(operation)
                            end
                status = supported ? :supported : :unsupported
                [operation, Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                  operation: operation, status: status, source: :provider_implementation, observed_at: now
                )]
              end
            end

            def capability_evidence(image:, model_data:)
              return {} if image

              now = Time.now.freeze
              predicates = Legion::Extensions::Llm::Grok::Provider::Capabilities
              model_capabilities = model_data[:capabilities]
              capabilities = {
                completion: [predicates.chat?(model_data), :provider_implementation],
                streaming: [predicates.streaming?(model_data), :provider_implementation],
                tools: [predicates.functions?(model_data), :provider_implementation],
                vision: if model_data.key?(:input_modalities)
                          [predicates.vision?(model_data),
                           :provider_catalog]
                        else
                          [nil, :default_false]
                        end,
                thinking: if model_capabilities.is_a?(Hash) && model_capabilities.key?(:reasoning_effort)
                            [predicates.thinking?(model_data), :provider_catalog]
                          else
                            [nil, :default_false]
                          end
              }
              capabilities.to_h do |capability, (supported, source)|
                status = if supported.nil? then :unknown
                         elsif supported then :supported
                         else :unsupported
                         end
                [capability, Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                  capability: capability, status: status, source: source, observed_at: now
                )]
              end
            end

            def value_evidence(value)
              return unknown_value unless value.is_a?(Integer) && value.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value,
                                                                    source: :provider_catalog)
            end

            def string_evidence(value)
              return unknown_value unless value.is_a?(String) && !value.empty?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value,
                                                                    source: :provider_catalog)
            end

            def unknown_value
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end
        end
      end
    end
  end
end
