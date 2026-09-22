# frozen_string_literal: true

require_relative 'lib/ask/permissions/version'

Gem::Specification.new do |spec|
  spec.name = 'ask-permissions'
  spec.version = Ask::Permissions::VERSION
  spec.authors = ['Kaka Ruto']
  spec.email = ['kaka@myrrlabs.com']

  spec.summary = 'Permission rules and approval workflows for ask-rb.'
  spec.description = 'Provides framework-independent permission rules, policies, ' \
                     'and approval queues for ask-rb agents and integrations.'
  spec.homepage = 'https://github.com/ask-rb/ask-permissions'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/master/lib"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md', 'VERSIONING.md',
                   'CONTRIBUTING.md', 'RELEASE.md']
  spec.require_paths = ['lib']

  spec.add_development_dependency 'minitest', '~> 5.25'
  spec.add_development_dependency 'mocha', '~> 3.1'
  spec.add_development_dependency 'rake', '~> 13.0'
end
