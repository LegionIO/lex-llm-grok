# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Grok::Provider do
  let(:provider) { described_class.new(grok_api_base: 'https://api.x.ai', grok_api_key: 'test-key') }
  let(:message) { Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello') }
  let(:response) { Struct.new(:body, :status) }

  it 'uses the real provider funnel to post Responses wire and return Canonical response' do
    wire = nil
    allow(provider.connection).to receive(:post) do |path, payload|
      wire = payload
      expect(path).to eq('/v1/responses')
      response.new({ 'id' => 'resp_1', 'model' => 'grok-4.7', 'status' => 'completed',
                     'output' => [{ 'type' => 'message', 'content' => [{ 'type' => 'output_text', 'text' => 'hi' }] }] }, 200)
    end

    result = provider.chat([message], model: 'grok-4.7')
    expect(wire[:input]).to eq([{ role: 'user', content: 'hello' }])
    expect(wire[:store]).to be(false)
    expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(result.text).to eq('hi')
  end

  it 'rejects noncanonical messages before any transport call' do
    allow(provider.connection).to receive(:post)
    expect { provider.chat([{ role: 'user', content: 'hello' }], model: 'grok-4.7') }
      .to raise_error(ArgumentError, /Canonical::Message/)
    expect(provider.connection).not_to have_received(:post)
  end

  it 'uses the documented image generation endpoint' do
    allow(provider.connection).to receive(:post) do |path, payload|
      expect(path).to eq('/v1/images/generations')
      expect(payload).to include(prompt: 'cat', model: 'grok-imagine-image-2.0')
      response.new({ 'data' => [{ 'url' => 'https://example.com/image.png' }] }, 200)
    end

    result = provider.image(prompt: 'cat', model: 'grok-imagine-image-2.0', size: nil)
    expect(result).to include(model: 'grok-imagine-image-2.0', image: 'https://example.com/image.png')
  end

  it 'refuses image params that would replace the exact selected model' do
    allow(provider.connection).to receive(:post)
    expect do
      provider.image(prompt: 'cat', model: 'grok-imagine-image-2.0', size: nil,
                     params: { model: 'different-model' })
    end.to raise_error(ArgumentError, /override/)
    expect(provider.connection).not_to have_received(:post)
  end

  it 'does a credentialed catalog read for live readiness' do
    allow(provider.connection).to receive(:get).with('/v1/models').and_return(response.new({ 'data' => [] }, 200))
    expect(provider.readiness(live: true)).to include(ready: true)
  end

  it 'normalizes xAI URL suffixes and rejects remote plaintext endpoints' do
    expect(described_class.normalize_api_base('https://api.x.ai/v1')).to eq('https://api.x.ai')
    expect(provider.connection.connection.ssl.verify).to be(true)
    expect do
      described_class.normalize_api_base('http://api.x.ai')
    end.to raise_error(Legion::Extensions::Llm::ConfigurationError, /HTTPS/)
  end

  it 'returns the final canonical response after SSE chunks, preserving encrypted reasoning' do
    stream_connection = Object.new
    full = { id: 'resp_stream', model: 'grok-4.7', status: 'completed',
             output: [{ type: 'reasoning', encrypted_content: 'cipher', summary: [{ text: 'thought' }] },
                      { type: 'message', content: [{ type: 'output_text', text: 'hi' }] }],
             usage: { input_tokens: 2, output_tokens: 1 } }
    stream_connection.define_singleton_method(:post) do |_path, _payload, &block|
      options = Struct.new(:on_data).new
      req = Struct.new(:headers, :options).new({}, options)
      block.call(req)
      env = Struct.new(:status).new(200)
      [{ type: 'response.output_text.delta', delta: 'hi' },
       { type: 'response.completed', response: full }].each do |event|
        wire = "data: #{Legion::JSON.dump(event)}\n\n"
        options.on_data.call(wire, wire.bytesize, env)
      end
    end
    provider.instance_variable_set(:@connection, stream_connection)
    chunks = []

    result = provider.stream_chat([message], model: 'grok-4.7') { |chunk| chunks << chunk }
    expect(chunks.any?(&:text_delta?)).to be(true)
    expect(chunks.last).to be_done
    expect(result.thinking.signature).to eq('cipher')
    expect(result.text).to eq('hi')
  end

  it 'rejects a terminal Responses body that contradicts streamed text' do
    stream_connection = Object.new
    stream_connection.define_singleton_method(:post) do |_path, _payload, &block|
      options = Struct.new(:on_data).new
      request = Struct.new(:headers, :options).new({}, options)
      block.call(request)
      env = Struct.new(:status).new(200)
      events = [
        { type: 'response.output_text.delta', delta: 'one' },
        { type: 'response.completed', response: {
          status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: 'two' }] }]
        } }
      ]
      events.each do |event|
        wire = "data: #{Legion::JSON.dump(event)}\n\n"
        options.on_data.call(wire, wire.bytesize, env)
      end
    end
    provider.instance_variable_set(:@connection, stream_connection)
    chunks = []

    expect { provider.stream_chat([message], model: 'grok-4.7') { |chunk| chunks << chunk } }
      .to raise_error(Legion::Extensions::Llm::ServerError, /disagrees/)
    expect(chunks.last).to be_error
  end

  it 'emits complete terminal text and tool calls when xAI sends no earlier deltas' do
    stream_connection = Object.new
    stream_connection.define_singleton_method(:post) do |_path, _payload, &block|
      options = Struct.new(:on_data).new
      block.call(Struct.new(:headers, :options).new({}, options))
      full = { status: 'completed', model: 'grok-4.7', output: [
        { type: 'message', content: [{ type: 'output_text', text: 'checking' }] },
        { type: 'function_call', call_id: 'call_1', name: 'lookup', arguments: '{"key":"x"}' }
      ] }
      wire = "data: #{Legion::JSON.dump({ type: 'response.completed', response: full })}\n\n"
      options.on_data.call(wire, wire.bytesize, Struct.new(:status).new(200))
    end
    provider.instance_variable_set(:@connection, stream_connection)
    chunks = []

    result = provider.stream_chat([message], model: 'grok-4.7') { |chunk| chunks << chunk }
    expect(chunks.map(&:type)).to include(:text_delta, :tool_call_delta, :done)
    expect(result.text).to eq('checking')
    expect(result.tool_calls.first.id).to eq('call_1')
  end
end
