# frozen_string_literal: true

require 'spec_helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/grok/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Grok::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  it 'binds the fleet subscription to its provider runner' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Grok::Runners::FleetWorker)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'starts only for an opted-in instance' do
    allow(Legion::Extensions::Llm::Grok).to receive(:discover_instances)
      .and_return(primary: { fleet: { enabled: true, respond_to_requests: true } })
    expect(actor.enabled?).to be(true)
  end
end
