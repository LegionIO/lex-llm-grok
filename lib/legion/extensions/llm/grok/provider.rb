# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/grok/translator'
require 'uri'

module Legion
  module Extensions
    module Llm
      module Grok
        # xAI Responses API implementation of the lex-llm provider funnel.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Logging::Helper

          class << self
            def slug = 'grok'
            def local? = false
            def default_transport = :http
            def default_tier = :cloud
            def configuration_options = %i[grok_api_base grok_api_key]
            def configuration_requirements = %i[grok_api_base grok_api_key]
            def capabilities = Capabilities

            def normalize_api_base(value)
              raw = value.to_s.sub(%r{/v1/?\z}, '').sub(%r{/?\z}, '')
              uri = URI.parse(raw)
              loopback = %w[localhost 127.0.0.1 ::1].include?(uri.host.to_s.downcase)
              valid = uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
                      uri.path.to_s.empty? && (uri.scheme == 'https' || (uri.scheme == 'http' && loopback))
              unless valid
                raise Legion::Extensions::Llm::ConfigurationError, 'Grok endpoint must be HTTPS or loopback HTTP'
              end

              raw
            rescue URI::InvalidURIError
              raise Legion::Extensions::Llm::ConfigurationError, 'Grok endpoint is invalid'
            end
          end

          # Model-type predicates used by discovery and provider registration.
          module Capabilities
            module_function

            def chat?(model)
              data = model_data(model)
              return false if image_model?(data)

              outputs = data[:output_modalities]
              outputs.nil? || Array(outputs).map(&:to_s).include?('text')
            end

            def streaming?(model) = chat?(model)
            def vision?(model) = Array(model_data(model)[:input_modalities]).map(&:to_s).include?('image')
            def functions?(model) = chat?(model)
            def embeddings?(_model) = false
            def thinking?(model) = !Array(model_data(model).dig(:capabilities, :reasoning_effort)).empty?

            def image_model?(model)
              data = model_data(model)
              data[:kind].to_s == 'image' || data[:id].to_s.start_with?('grok-imagine-image')
            end

            def critical_capabilities_for(model)
              return [] if image_model?(model)

              [
                ('streaming' if streaming?(model)),
                ('function_calling' if functions?(model)),
                ('vision' if vision?(model)),
                ('thinking' if thinking?(model))
              ].compact
            end

            def model_data(model)
              model.is_a?(Hash) ? model.transform_keys(&:to_sym) : { id: model.to_s }
            end
          end

          def initialize(config)
            super
            if self.config.grok_api_key.to_s.strip.empty?
              raise Legion::Extensions::Llm::ConfigurationError,
                    'grok_api_key is required'
            end

            connection.connection.ssl.verify = true if api_base.start_with?('https://')
          end

          def api_base
            base = config.grok_api_base
            raise Legion::Extensions::Llm::ConfigurationError, 'grok_api_base is required' if base.to_s.empty?

            self.class.normalize_api_base(base)
          end

          def headers
            identity_headers.merge('Authorization' => "Bearer #{config.grok_api_key}")
          end

          def completion_url = '/v1/responses'
          def stream_url = completion_url
          def models_url = '/v1/models'
          def images_url(**) = '/v1/images/generations'

          def translator
            @translator ||= Legion::Extensions::Llm::Grok::Translator.new
          end

          def render_payload(messages, tools:, tool_prefs:, model:, stream:, schema:, thinking:, params:)
            unless model.is_a?(String) && !model.empty?
              raise ArgumentError, 'Grok selected model must be a nonempty String'
            end

            canonical_params = if params.nil?
                                 Legion::Extensions::Llm::Canonical::Params.build
                               elsif params.is_a?(Legion::Extensions::Llm::Canonical::Params)
                                 params
                               else
                                 Legion::Extensions::Llm::Canonical::Params.from_hash(params)
                               end
            if schema
              if canonical_params.response_format && canonical_params.response_format != schema
                raise ArgumentError, 'Grok received conflicting response format and schema'
              end

              format = { type: 'json_schema', name: 'response', schema: schema, strict: true }
              canonical_params = canonical_params.with(response_format: format)
            end
            request = Legion::Extensions::Llm::Canonical::Request.build(
              messages: messages, tools: tools, params: canonical_params,
              tool_choice: tool_choice_from(tool_prefs), thinking: thinking,
              stream: stream, metadata: { model: model }
            )
            translator.render_request(request)
          end

          def parse_completion_response(response)
            translator.parse_response(response.body)
          end

          def build_chunk(data)
            translator.parse_chunk(data)
          end

          # xAI's terminal SSE event is the authoritative full response. The
          # shared parser and accumulator emit live Canonical chunks; the final
          # event is translated once into the returned Canonical response.
          def stream_response(connection, payload, additional_headers = {}, model: nil, &)
            _ = model
            accumulator = Legion::Extensions::Llm::StreamAccumulator.new
            final_response = nil
            on_data = build_on_data_handler do |data|
              next unless data.is_a?(Hash)

              event = data['type'] || data[:type]
              if %w[response.completed response.incomplete].include?(event)
                final_response = translator.parse_response(data['response'] || data[:response])
                complete_missing_stream_items!(accumulator: accumulator, final_response: final_response, &)
              end
              Array(build_chunk(data)).each do |chunk|
                accumulator.add(chunk).each(&)
              end
            end
            connection.post(stream_url, payload) do |request|
              request.headers = additional_headers.merge(request.headers) unless additional_headers.empty?
              if faraday_1?
                request.options[:on_data] = on_data
              else
                request.options.on_data = on_data
              end
            end
            accumulator.flush_pending_chunk.each(&)
            unless final_response
              raise Legion::Extensions::Llm::ServerError,
                    'xAI stream ended without a terminal response'
            end

            verify_stream_completion!(accumulator: accumulator, final_response: final_response)
            yield Legion::Extensions::Llm::Canonical::Chunk.done(request_id: nil,
                                                                 usage: final_response.usage,
                                                                 stop_reason: final_response.stop_reason)
            final_response
          rescue StandardError => e
            yield Legion::Extensions::Llm::Canonical::Chunk.error_chunk(error: e, request_id: nil)
            raise
          end

          # xAI has no separate health endpoint. An authenticated model catalog
          # read establishes live readiness without sending an inference request.
          def readiness(live: false)
            result = { provider: :grok, configured: configured?, ready: configured?, live: live }
            return result.merge(health: { checked: false }) unless live

            response = connection.get(models_url)
            models = response.body['data'] || response.body[:data]
            result.merge(ready: response.status == 200 && models.is_a?(Array),
                         health: { status: response.status })
          rescue Faraday::Error, Legion::Extensions::Llm::Error => e
            handle_exception(e, level: :warn, operation: 'grok.provider.readiness')
            result.merge(ready: false, health: { error_class: e.class.name })
          end

          def embed(text:, model:, **)
            _ = text
            raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
              provider: :grok, capability: :embed, model: model
            )
          end

          def moderate(input:, model:, **)
            _ = input
            raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
              provider: :grok, capability: :moderate, model: model
            )
          end

          def transcribe(audio_file:, model:, **)
            _ = audio_file
            raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
              provider: :grok, capability: :transcribe, model: model
            )
          end

          def translate(audio_file:, model:, **)
            _ = audio_file
            raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
              provider: :grok, capability: :translate, model: model
            )
          end

          def speak(text:, model:, **)
            _ = text
            raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
              provider: :grok, capability: :speak, model: model
            )
          end

          def render_image_payload(prompt, model:, size:, with:, mask:, params:)
            raise ArgumentError, 'Grok image edits are not implemented' if with || mask
            raise ArgumentError, 'Grok image model must be a String' unless model.is_a?(String) && !model.empty?
            raise ArgumentError, 'Grok image params must be a Hash' unless params.is_a?(Hash)

            forbidden = params.keys.map(&:to_s) & %w[model prompt size image mask]
            raise ArgumentError, "Grok image params override #{forbidden.join(', ')}" unless forbidden.empty?

            { prompt: prompt, model: model, size: size }.merge(params).compact
          end

          def parse_image_response(response, model:)
            image = response.body.fetch('data', []).first
            raise ArgumentError, 'Grok image response has no data' unless image.is_a?(Hash)

            { model: model, image: image['url'] || image['b64_json'], size: image['size'] }.compact
          end

          private

          def complete_missing_stream_items!(accumulator:, final_response:, &)
            partial = accumulator.to_response(model: final_response.model)
            if partial.text.empty? && !final_response.text.empty?
              chunk = Legion::Extensions::Llm::Canonical::Chunk.text_delta(
                delta: final_response.text, request_id: nil
              )
              accumulator.add(chunk).each(&)
            end
            known_ids = partial.tool_calls.map(&:id)
            final_response.tool_calls.each_with_index do |call, index|
              next if known_ids.include?(call.id)

              chunk = Legion::Extensions::Llm::Canonical::Chunk.tool_call_delta(
                tool_call: { id: call.id, name: call.name,
                             arguments: Legion::JSON.dump(call.arguments), index: index },
                request_id: nil
              )
              accumulator.add(chunk).each(&)
            end
          end

          def verify_stream_completion!(accumulator:, final_response:)
            partial = accumulator.to_response(model: final_response.model)
            partial_calls = partial.tool_calls.map { |call| [call.id, call.name, call.arguments] }
            final_calls = final_response.tool_calls.map { |call| [call.id, call.name, call.arguments] }
            return if partial.text == final_response.text &&
                      partial_calls == final_calls

            raise Legion::Extensions::Llm::ServerError, 'xAI stream disagrees with terminal response'
          end

          def tool_choice_from(preferences)
            return nil unless preferences

            choice = preferences[:choice] || preferences['choice']
            return nil unless choice
            return choice.to_sym if %w[auto none required].include?(choice.to_s)
            return :any if choice.to_s == 'any'

            { name: choice.to_s }
          end
        end
      end
    end
  end
end
