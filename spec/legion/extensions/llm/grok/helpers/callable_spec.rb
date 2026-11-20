# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Grok::Helpers::Callable do
  let(:callable) do
    described_class.new(instance_cfg: { grok_api_base: 'https://api.x.ai', grok_api_key: 'test-key' })
  end
  let(:message) { Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello') }

  it 'carries fleet Canonical params through the provider funnel' do
    provider = Legion::Extensions::Llm::Grok::Provider.new(grok_api_base: 'https://api.x.ai', grok_api_key: 'test-key')
    callable.instance_variable_set(:@provider, provider)
    wire = nil
    allow(provider.connection).to receive(:post) do |_path, payload|
      wire = payload
      Struct.new(:body).new({ 'status' => 'completed', 'output' => [] })
    end

    callable.chat([message], model: 'grok-4.7', params: { temperature: 0.4, max_tokens: 24 })
    expect(wire).to include(model: 'grok-4.7', temperature: 0.4, max_output_tokens: 24)
    expect(wire[:input].first).to eq(role: 'user', content: 'hello')
  end

  it 'refuses reuse after disconnect and classifies that exact instance as unavailable' do
    callable.disconnect
    expect { callable.chat([message], model: 'grok-4.7') }
      .to raise_error(Legion::Extensions::Llm::Inventory::Errors::CallableDisposedError)
    error = Legion::Extensions::Llm::Inventory::Errors::CallableDisposedError.new('disconnected')
    expect(callable.normalize_dispatch_error(error: error).kind).to eq(:instance_unavailable)
  end

  it 'uses the shared provider outcome taxonomy for rate limits' do
    error = Legion::Extensions::Llm::RateLimitError.new('rate limited')
    expect(callable.normalize_dispatch_error(error: error).kind).to eq(:rate_limited)
  end
end
