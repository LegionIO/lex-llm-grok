# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/grok/runners/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Grok::Runners::FleetWorker do
  it 'passes the exact delivered envelope and registry to the shared responder' do
    responder = Legion::Extensions::Llm::Fleet::ProviderResponder
    registry = Legion::Extensions::Llm::Inventory::Registry
    payload = { request_id: 'req_1', operation: 'chat', model: 'grok-4.7' }
    allow(responder).to receive(:call).and_return(success: true)

    result = described_class.handle_fleet_request(value: payload, delivery: :delivery, properties: :properties)
    expect(result).to eq(success: true)
    expect(responder).to have_received(:call).with(payload: payload, provider_family: :grok,
                                                   registry: registry, delivery: :delivery,
                                                   properties: :properties)
  end
end
