# frozen_string_literal: true

require_relative 'lib/legion/extensions/llm/grok/version'

Gem::Specification.new do |spec|
  spec.name = 'lex-llm-grok'
  spec.version = Legion::Extensions::Llm::Grok::VERSION
  spec.authors = ['LegionIO']
  spec.summary = 'LegionIO xAI Grok provider extension'
  spec.description = 'Canonical xAI Responses API provider with inventory discovery and fleet execution.'
  spec.homepage = 'https://github.com/LegionIO/lex-llm-grok'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.files = Dir.glob('lib/**/*').select { |file| File.file?(file) } + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ['lib']

  spec.add_dependency 'legion-json', '>= 1.2.1'
  spec.add_dependency 'legion-logging', '>= 1.3.2'
  spec.add_dependency 'legion-settings', '>= 1.4.2'
  spec.add_dependency 'legion-transport', '>= 1.4.14'
  spec.add_dependency 'lex-llm', '>= 0.8.6'
end
