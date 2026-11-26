ENV["RAILS_ENV"] ||= "test"
require "openssl"
ENV["GITHUB_APP_ID"] ||= "12345"
ENV["GITHUB_APP_PRIVATE_KEY"] ||= OpenSSL::PKey::RSA.new(2048).to_pem
ENV["GITHUB_APP_WEBHOOK_SECRET"] ||= "webhook-secret"

require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/github_helper"
require_relative "test_helpers/memory_cache_helper"

WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all

    include GitHubHelper

    teardown { GitHost::GitHub::TOKENS.clear }
  end
end
