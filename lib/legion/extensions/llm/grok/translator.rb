# frozen_string_literal: true

require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/responses/tool_arguments'
require 'legion/json'

module Legion
  module Extensions
    module Llm
      module Grok
        # The only Grok wire boundary. Shared execution passes Canonical types;
        # this translator renders xAI Responses input and parses its output.
        class Translator
          REASONING_EFFORTS = %w[low medium high xhigh].freeze
          XHIGH_MODELS = %w[grok-4.6 grok-4.7 grok-4.20-multi-agent].freeze
          RESPONSE_CONTENT_TYPES = %w[output_text refusal].freeze

          def render_request(request)
            unless request.is_a?(Legion::Extensions::Llm::Canonical::Request)
              raise ArgumentError, 'grok request must be Canonical::Request'
            end

            model = request.metadata[:model]
            unless model.is_a?(String) && !model.empty?
              raise ArgumentError, 'grok request has no exact selected model String'
            end

            wire = { model: model, input: render_input(request), stream: request.stream, store: false }
            wire[:tools] = render_tools(request.tools) unless request.tools.empty?
            wire[:tool_choice] = render_tool_choice(request.tool_choice) if request.tool_choice
            wire.merge!(render_params(request.params)) if request.params
            wire[:reasoning] = render_reasoning(request.thinking, model: model) if request.thinking
            wire[:include] = ['reasoning.encrypted_content']
            wire
          end

          def parse_response(raw)
            body = symbolize(raw)
            raise ArgumentError, 'grok response must be an object' unless body.is_a?(Hash)
            raise ArgumentError, 'grok response has no output array' unless body[:output].is_a?(Array)
            raise Legion::Extensions::Llm::ServerError, 'xAI response failed' if body[:status] == 'failed'
            unless %w[completed incomplete].include?(body[:status])
              raise ArgumentError, "Grok response has unsupported status #{body[:status].inspect}"
            end

            output = body[:output]
            validate_output!(output)
            calls = output.filter_map { |item| parse_tool_call(item) if item[:type] == 'function_call' }
            parts = output.filter { |item| item[:type] == 'message' }.flat_map { |item| item[:content] }
            text = parts.filter_map { |part| part[:text] || part[:refusal] }.join
            reasoning_items = output.select { |item| item[:type] == 'reasoning' }
            replay_items = reasoning_items.select { |item| item[:encrypted_content].is_a?(String) }
            thinking = parse_thinking(reasoning_items)
            refusal = parts.any? { |part| part[:type] == 'refusal' }
            annotations = parts.flat_map { |part| Array(part[:annotations]) }
            Legion::Extensions::Llm::Canonical::Response.build(
              text: text, thinking: thinking, tool_calls: calls,
              usage: parse_usage(body[:usage]),
              stop_reason: stop_reason(body, calls, refusal: refusal),
              model: body[:model],
              metadata: { grok_response_id: body[:id], grok_reasoning: replay_items,
                          grok_annotations: annotations }.compact
            )
          end

          # Data in xAI SSE events includes its event type. The shared SSE
          # parser invokes this for every JSON data frame. A completed function
          # item is emitted once with its authoritative call_id and full JSON.
          def parse_chunk(raw)
            data = symbolize(raw)
            case data[:type]
            when 'response.output_text.delta'
              Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: data.fetch(:delta), request_id: nil)
            when 'response.reasoning_text.delta', 'response.reasoning_summary_text.delta'
              Legion::Extensions::Llm::Canonical::Chunk.thinking_delta(delta: data.fetch(:delta), request_id: nil)
            when 'response.output_item.done'
              item = data[:item]
              return nil unless item.is_a?(Hash) && item[:type] == 'function_call'

              Legion::Extensions::Llm::Canonical::Chunk.tool_call_delta(
                tool_call: { id: item.fetch(:call_id), name: item.fetch(:name),
                             arguments: item.fetch(:arguments), index: data[:output_index] },
                request_id: nil
              )
            when 'response.completed', 'response.incomplete'
              response = data.fetch(:response)
              usage = parse_usage(response[:usage])
              reason = stop_reason(response, Array(response[:output]).filter { |item| item[:type] == 'function_call' })
              Legion::Extensions::Llm::Canonical::Chunk.build(type: :usage, usage: usage,
                                                              stop_reason: reason, request_id: nil)
            when 'response.failed'
              raise Legion::Extensions::Llm::ServerError, 'xAI response failed'
            end
          end

          private

          def validate_output!(output)
            output.each do |item|
              raise ArgumentError, 'Grok output item must be an object' unless item.is_a?(Hash)

              case item[:type]
              when 'reasoning', 'function_call' then next
              when 'message'
                raise ArgumentError, 'Grok message content must be an array' unless item[:content].is_a?(Array)

                item[:content].each do |part|
                  valid = part.is_a?(Hash) && RESPONSE_CONTENT_TYPES.include?(part[:type])
                  raise ArgumentError, 'Grok returned an unsupported message content part' unless valid
                end
              else
                raise ArgumentError, "Grok returned an unsupported output item #{item[:type].inspect}"
              end
            end
          end

          def symbolize(value)
            return Legion::JSON.load(value) if value.is_a?(String)

            Legion::JSON.load(Legion::JSON.dump(value))
          end

          def render_input(request)
            input = []
            if request.system.is_a?(String) && !request.system.empty?
              input << { role: 'system',
                         content: request.system }
            end
            request.messages.each do |message|
              unless message.is_a?(Legion::Extensions::Llm::Canonical::Message)
                raise ArgumentError, 'grok input must be Canonical::Message'
              end

              input.concat(render_message(message))
            end
            input
          end

          def render_message(message)
            if message.role == :tool
              raise ArgumentError, 'Grok tool result has no call ID' if message.tool_call_id.to_s.empty?

              return [{ type: 'function_call_output', call_id: message.tool_call_id.to_s,
                        output: message.content.is_a?(String) ? message.content : Legion::JSON.dump(message.content) }]
            end

            items = []
            reasoning = message.metadata[:grok_reasoning] || message.metadata['grok_reasoning']
            items.concat(render_prior_reasoning(reasoning)) if reasoning
            content = render_content(message.content)
            items << { role: message.role.to_s, content: content } unless content.nil?
            Array(message.tool_calls).each do |call|
              unless call.is_a?(Legion::Extensions::Llm::Canonical::ToolCall)
                raise ArgumentError, 'grok tool history must be Canonical::ToolCall'
              end

              items << { type: 'function_call', call_id: call.id, name: call.name,
                         arguments: Legion::JSON.dump(call.arguments) }
            end
            items
          end

          def render_prior_reasoning(reasoning)
            entries = reasoning.is_a?(Array) ? reasoning : [reasoning]
            entries.each do |entry|
              valid = entry.is_a?(Hash) && (entry[:type] || entry['type']) == 'reasoning' &&
                      (entry[:encrypted_content] || entry['encrypted_content']).is_a?(String)
              raise ArgumentError, 'grok reasoning metadata must carry encrypted reasoning items' unless valid
            end
            entries
          end

          def render_content(content)
            return content if content.is_a?(String) || content.nil?

            blocks = content.is_a?(Array) ? content : [content]
            blocks.map do |block|
              unless block.is_a?(Legion::Extensions::Llm::Canonical::ContentBlock)
                raise ArgumentError, 'grok content must be Canonical::ContentBlock'
              end

              case block.type
              when :text then { type: 'input_text', text: block.text }
              when :image then render_image_block(block)
              else
                raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
                  provider: :grok, capability: block.type
                )
              end
            end
          end

          def render_image_block(block)
            image_url = if block.source_type == :base64
                          "data:#{block.media_type};base64,#{block.data}"
                        elsif block.source_type == :url
                          block.data
                        else
                          raise ArgumentError, 'grok image source must be base64 or url'
                        end
            { type: 'input_image', image_url: image_url, detail: block.detail }.compact
          end

          def render_tools(tools)
            tools.values.map do |tool|
              unless tool.is_a?(Legion::Extensions::Llm::Canonical::ToolDefinition)
                raise ArgumentError, 'grok tools must be Canonical::ToolDefinition'
              end

              { type: 'function', name: tool.name, description: tool.description,
                parameters: Legion::Extensions::Llm::Canonical::ToolDefinition.normalize_parameters(tool.parameters) }
            end
          end

          def render_tool_choice(choice)
            return choice.to_s if %i[auto none required].include?(choice)
            return 'required' if choice == :any
            return { type: 'function', name: choice[:name] || choice['name'] } if choice.is_a?(Hash)

            raise ArgumentError, "unsupported Grok tool choice #{choice.inspect}"
          end

          def render_params(params)
            unless params.is_a?(Legion::Extensions::Llm::Canonical::Params)
              raise ArgumentError, 'grok params must be Canonical::Params'
            end
            raise ArgumentError, 'Grok received unsupported provider params' unless params.metadata.empty?

            unsupported = %i[top_k stop_sequences seed frequency_penalty presence_penalty].reject do |field|
              params.public_send(field).nil?
            end
            raise ArgumentError, "Grok Responses does not support #{unsupported.join(', ')}" unless unsupported.empty?

            result = { max_output_tokens: params.max_tokens, temperature: params.temperature,
                       top_p: params.top_p }.compact
            result[:text] = { format: render_format(params.response_format) } if params.response_format
            result
          end

          def render_format(format)
            return { type: format } if format.is_a?(String)

            type = format[:type] || format['type']
            if type.to_s == 'json_schema'
              source = format[:json_schema] || format['json_schema'] || format
              schema = source[:schema] || source['schema']
              name = source[:name] || source['name']
              raise ArgumentError, 'Grok JSON schema needs name and schema' if name.to_s.empty? || !schema.is_a?(Hash)

              return { type: 'json_schema', name: name, schema: schema,
                       strict: source.key?(:strict) ? source[:strict] : source['strict'] }.compact
            end
            return { type: type.to_s } if type

            raise ArgumentError, 'Grok response format needs a type'
          end

          def render_reasoning(thinking, model:)
            unless thinking.is_a?(Legion::Extensions::Llm::Canonical::Thinking::Config)
              raise ArgumentError, 'grok thinking must be Canonical::Thinking::Config'
            end
            raise ArgumentError, 'Grok received unsupported thinking metadata' unless thinking.metadata.empty?

            unless thinking.enabled?
              return { effort: 'none' } if model.start_with?('grok-4.3')

              raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
                provider: :grok, capability: :reasoning_disable, model: model
              )
            end

            effort = thinking.resolved_effort
            if effort && !REASONING_EFFORTS.include?(effort)
              raise ArgumentError,
                    "Grok does not support reasoning effort #{effort}"
            end
            if effort == 'xhigh' && XHIGH_MODELS.none? { |prefix| model.start_with?(prefix) }
              raise Legion::Extensions::Llm::Errors::UnsupportedCapability.new(
                provider: :grok, capability: :xhigh_reasoning, model: model
              )
            end

            reasoning = { effort: effort || 'high' }
            reasoning[:summary] = thinking.summary.to_s if thinking.summary
            reasoning
          end

          def parse_tool_call(item)
            Legion::Extensions::Llm::Canonical::ToolCall.build(name: item.fetch(:name), id: item.fetch(:call_id),
                                                               arguments: Legion::Extensions::Llm::Responses::ToolArguments.parse!(item.fetch(:arguments)))
          end

          def parse_thinking(reasoning_items)
            item = reasoning_items.first
            return nil unless item

            summary = reasoning_items.flat_map { |entry| Array(entry[:summary]) }.filter_map { |part| part[:text] }.join
            signature = reasoning_items.filter_map { |entry| entry[:encrypted_content] }.first
            Legion::Extensions::Llm::Canonical::Thinking.build(content: summary, signature: signature,
                                                               metadata: { grok_reasoning: reasoning_items })
          end

          def parse_usage(raw)
            return nil unless raw.is_a?(Hash)

            units = {}
            units[:cost_in_usd_ticks] = raw[:cost_in_usd_ticks] if raw[:cost_in_usd_ticks]
            cache_read = raw.dig(:input_tokens_details, :cached_tokens) ||
                         raw.dig(:prompt_tokens_details, :cached_tokens)
            thinking = raw.dig(:output_tokens_details, :reasoning_tokens) ||
                       raw.dig(:completion_tokens_details, :reasoning_tokens)
            Legion::Extensions::Llm::Canonical::Usage.build(
              input_tokens: raw[:input_tokens] || raw[:prompt_tokens],
              output_tokens: raw[:output_tokens] || raw[:completion_tokens],
              cache_read_tokens: cache_read, thinking_tokens: thinking, units: units
            )
          end

          def stop_reason(body, calls, refusal: false)
            return :content_filter if refusal
            return :tool_use unless calls.empty?

            if body[:status] == 'incomplete'
              return :content_filter if body.dig(:incomplete_details, :reason) == 'content_filter'

              return :max_tokens
            end
            return :error if body[:status] == 'failed'

            :end_turn
          end
        end
      end
    end
  end
end
