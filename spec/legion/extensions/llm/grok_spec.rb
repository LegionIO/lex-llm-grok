# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Grok do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:translator) { described_class::Translator.new }

  def request(messages:, tools: {}, params: nil, thinking: nil, stream: false, model: 'grok-4.7')
    canonical::Request.build(messages: messages, tools: tools, params: params, thinking: thinking,
                             stream: stream, metadata: { model: model })
  end

  it 'renders canonical text, tools, image input and prior tool results for Responses' do
    tool = canonical::ToolDefinition.build(name: 'lookup', description: 'Find a value', parameters: { type: 'object' })
    call = canonical::ToolCall.build(name: 'lookup', id: 'call_1', arguments: { key: 'x' })
    image = canonical::ContentBlock.image(data: 'AQID', media_type: 'image/png', source_type: :base64)
    messages = [
      canonical::Message.build(role: :user, content: [canonical::ContentBlock.text('describe'), image]),
      canonical::Message.build(role: :assistant, tool_calls: [call]),
      canonical::Message.build(role: :tool, tool_call_id: 'call_1', content: 'found')
    ]
    wire = translator.render_request(request(messages: messages, tools: { 'lookup' => tool }))

    expect(wire[:model]).to eq('grok-4.7')
    expect(wire[:input].first[:content].last).to include(type: 'input_image', image_url: 'data:image/png;base64,AQID')
    expect(wire[:input][1]).to include(type: 'function_call', call_id: 'call_1', name: 'lookup')
    expect(wire[:input][2]).to include(type: 'function_call_output', call_id: 'call_1', output: 'found')
    expect(wire[:tools].first).to include(type: 'function', name: 'lookup')
  end

  it 'parses a Responses result into canonical text, tool calls, usage and reasoning' do
    raw = { id: 'resp_1', model: 'grok-4.7', status: 'completed', output: [
      { type: 'reasoning', encrypted_content: 'encrypted', summary: [{ text: 'summary' }] },
      { type: 'message', content: [{ type: 'output_text', text: 'hello' }] },
      { type: 'function_call', call_id: 'call_1', name: 'lookup', arguments: '{"key":"x"}' }
    ], usage: { input_tokens: 10, output_tokens: 5, output_tokens_details: { reasoning_tokens: 2 } } }

    result = translator.parse_response(raw)
    expect(result).to be_a(canonical::Response)
    expect(result.text).to eq('hello')
    expect(result.tool_calls.first.arguments).to eq('key' => 'x')
    expect(result.thinking.signature).to eq('encrypted')
    continued = canonical::Message.build(role: :assistant, content: result.text,
                                         metadata: { grok_reasoning: result.metadata[:grok_reasoning] })
    expect(translator.render_request(request(messages: [continued]))[:input].first[:encrypted_content]).to eq('encrypted')
    expect(result.usage.thinking_tokens).to eq(2)
    expect(result.stop_reason).to eq(:tool_use)
  end

  it 'parses streaming text, completed tool calls and usage' do
    text = translator.parse_chunk(type: 'response.output_text.delta', delta: 'hel')
    call = translator.parse_chunk(type: 'response.output_item.done', output_index: 1,
                                  item: { type: 'function_call', call_id: 'call_1', name: 'lookup', arguments: '{}' })
    done = translator.parse_chunk(type: 'response.completed', response: {
                                    status: 'completed', output: [], usage: { input_tokens: 2, output_tokens: 1 }
                                  })

    expect(text).to be_a(canonical::Chunk)
    expect(text.delta).to eq('hel')
    expect(call.tool_call).to include(id: 'call_1', name: 'lookup')
    expect(done.usage.input_tokens).to eq(2)
  end

  it 'rejects non-canonical input and unsupported sampling instead of dropping it' do
    params = canonical::Params.build(seed: 1)
    expect { translator.render_request(request(messages: [], params: params)) }.to raise_error(ArgumentError, /seed/)
    expect { translator.render_request('raw') }.to raise_error(ArgumentError, /Canonical::Request/)
  end

  it 'maps canonical reasoning effort and refuses an unsupported disable request' do
    thinking = canonical::Thinking::Config.build(effort: 'high', summary: :detailed)
    wire = translator.render_request(request(messages: [], thinking: thinking))
    expect(wire[:reasoning]).to eq(effort: 'high', summary: 'detailed')
    expect(wire[:include]).to eq(['reasoning.encrypted_content'])

    disabled = canonical::Thinking::Config.build(enabled: false)
    expect { translator.render_request(request(messages: [], thinking: disabled)) }
      .to raise_error(Legion::Extensions::Llm::Errors::UnsupportedCapability)
    expect(translator.render_request(request(messages: [], thinking: disabled, model: 'grok-4.3'))[:reasoning])
      .to eq(effort: 'none')
    xhigh = canonical::Thinking::Config.build(effort: 'xhigh')
    expect { translator.render_request(request(messages: [], thinking: xhigh, model: 'grok-4.5')) }
      .to raise_error(Legion::Extensions::Llm::Errors::UnsupportedCapability)
  end

  it 'raises on a failed Responses body instead of returning an empty success' do
    expect { translator.parse_response(status: 'failed', output: []) }
      .to raise_error(Legion::Extensions::Llm::ServerError)
  end

  it 'translates a client JSON schema into Responses text.format' do
    params = canonical::Params.build(response_format: {
                                       'type' => 'json_schema', 'json_schema' => {
                                         'name' => 'answer', 'schema' => { 'type' => 'object' }, 'strict' => true
                                       }
                                     })
    wire = translator.render_request(request(messages: [], params: params))
    expect(wire[:text][:format]).to eq(type: 'json_schema', name: 'answer',
                                       schema: { 'type' => 'object' }, strict: true)
  end

  it 'discovers only configured authenticated instances' do
    allow(described_class).to receive(:settings).and_return(instances: {
                                                              primary: { endpoint: 'https://api.x.ai', credentials: { api_key: 'test-key' } },
                                                              disabled: { endpoint: 'https://api.x.ai', credentials: { api_key: 'test-key' }, enabled: false },
                                                              empty: { endpoint: 'https://api.x.ai' }
                                                            })
    allow(ENV).to receive(:[]).with('XAI_API_KEY').and_return(nil)

    instances = described_class.discover_instances
    expect(instances.keys).to eq([:primary])
    expect(instances[:primary][:grok_api_base]).to eq('https://api.x.ai')
  end
end
