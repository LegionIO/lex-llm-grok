# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/fleet_envelope'

RSpec.describe Legion::Extensions::Llm::Grok::Runners::Discovery do
  let(:instance) { { grok_api_base: 'https://api.x.ai', grok_api_key: 'test-key', tier: :cloud } }
  let(:key) do
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: :grok, instance_id: 'primary')
  end

  it 'reads the three xAI model catalogs and keeps only models with exact operation evidence' do
    responses = {
      '/v1/models' => { data: [{ id: 'grok-4.7', context_length: 100_000 }, { id: 'grok-imagine-image-2.0' }] },
      '/v1/language-models' => { models: [{ id: 'grok-4.7', input_modalities: %w[text image],
                                            capabilities: { reasoning_effort: %w[low high] } }] },
      '/v1/image-generation-models' => { models: [{ id: 'grok-imagine-image-2.0' }] }
    }
    conn = Object.new
    conn.define_singleton_method(:get) do |path|
      Struct.new(:status, :body).new(200, Legion::JSON.dump(responses.fetch(path)))
    end
    allow(described_class).to receive(:build_connection).and_return(conn)

    catalog = described_class.fetch_raw_models(instance_cfg: instance)
    expect(catalog.map { |model| model[:kind] }).to eq(%i[language image])
    chat = described_class.build_offering_draft(instance_cfg: instance, instance_key: key,
                                                model_id: catalog.first[:id], model_data: catalog.first)
    image = described_class.build_offering_draft(instance_cfg: instance, instance_key: key,
                                                 model_id: catalog.last[:id], model_data: catalog.last)
    expect(chat.operation_evidence[:chat].status).to eq(:supported)
    expect(chat.operation_evidence[:image].status).to eq(:unsupported)
    expect(chat.capability_evidence[:vision].status).to eq(:supported)
    expect(chat.context_evidence.value).to eq(100_000)
    expect(image.operation_evidence[:image].status).to eq(:supported)
    expect(image.operation_evidence[:chat].status).to eq(:unsupported)
  end

  it 'publishes an authenticated model through the shared Inventory registry' do
    registry = Legion::Extensions::Llm::Inventory::Registry
    registry.reset!
    described_class.reset_state!
    Legion::Settings.loader.settings[:extensions][:llm] = { grok: Legion::Extensions::Llm::Grok.default_settings }
    Legion::Settings.loader.settings[:llm] = { routing: { tier_weights: { cloud: 100 } } }
    allow(Legion::Extensions::Llm::Grok).to receive(:discover_instances).and_return(primary: instance)
    allow(described_class).to receive_messages(fetch_raw_models: [
                                                 { id: 'grok-4.7', kind: :language, input_modalities: ['text'],
                                                   capabilities: { reasoning_effort: ['high'] }, context_length: 131_072 }
                                               ], check_health: Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'catalog ready'))

    described_class.reconcile_instances
    record = registry.snapshot.instance(instance_key: key)
    expect(record).not_to be_nil
    expect(record.availability.state).to eq(:available)
    lane = registry.snapshot.lanes_for(instance_key: key).find { |candidate| candidate.operation == :chat }
    expect(lane.model).to eq('grok-4.7')

    provider = Legion::Extensions::Llm::Grok::Provider.new(instance)
    allow(provider.connection).to receive(:post).and_return(
      Struct.new(:body).new({ 'status' => 'completed', 'model' => 'grok-4.7',
                              'output' => [{ 'type' => 'message', 'content' => [{ 'type' => 'output_text', 'text' => 'ok' }] }] })
    )
    allow(Legion::Extensions::Llm::Grok::Provider).to receive(:new).and_return(provider)
    envelope = {
      execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: lane.lane_id, provider: 'grok', provider_instance: 'primary',
      model: 'grok-4.7', operation: 'chat',
      params: { messages: [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi').to_h] }
    }
    wire = Legion::JSON.load(Legion::JSON.dump(envelope))
    worker = Legion::Extensions::Llm::Fleet::WorkerExecution
    result = worker.dispatch!(envelope: Legion::Extensions::Llm::Fleet::FleetEnvelope.wrap(wire), registry: registry)
    expect(result.text).to eq('ok')
    bad = wire.merge(model: 'other')
    expect do
      worker.dispatch!(envelope: Legion::Extensions::Llm::Fleet::FleetEnvelope.wrap(bad), registry: registry)
    end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    expect(provider.connection).to have_received(:post).once
  ensure
    described_class.reset_state!
    registry.reset!
  end

  it 'treats an unavailable catalog as a failed fetch rather than an empty publication' do
    conn = Object.new
    conn.define_singleton_method(:get) { |_path| Struct.new(:status).new(503) }
    allow(described_class).to receive(:build_connection).and_return(conn)

    expect { described_class.fetch_raw_models(instance_cfg: instance) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure)
  end

  it 'verifies TLS for authenticated xAI catalog requests' do
    connection = described_class.build_connection(base_url: 'https://api.x.ai', instance_cfg: instance,
                                                  timeout: 15, open_timeout: 5)
    expect(connection.ssl.verify).to be(true)
    expect(connection.headers['Authorization']).to eq('Bearer test-key')
  end

  it 'rejects a conflicting catalog model identity before publication' do
    expect do
      described_class.build_offering_draft(instance_cfg: instance, instance_key: key,
                                           model_id: 'grok-4.7', model_data: { id: 'other', kind: :language })
    end.to raise_error(ArgumentError, /disagrees/)
  end
end
