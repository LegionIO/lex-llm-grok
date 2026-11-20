# frozen_string_literal: true

require 'legion/extensions/llm/discovery/actor'

return unless defined?(Legion::Extensions::Llm::Discovery::Actor)

module Legion
  module Extensions
    module Llm
      module Grok
        module Actor
          class Discovery < Legion::Extensions::Llm::Discovery::Actor; end
        end
      end
    end
  end
end
