require "test_helper"

class AgentTokenTest < ActiveSupport::TestCase
  test "revoking hangs up the agents on the token's open cables" do
    token = agent_tokens(:web_1)
    hung_up = []
    AgentChannel.singleton_class.alias_method(:original_disconnect, :disconnect)
    AgentChannel.define_singleton_method(:disconnect) { |t| hung_up << t }

    token.revoke

    assert token.revoked?
    assert_equal [ token ], hung_up
    assert_nil AgentToken.authenticate("meridian_web1token")
  ensure
    AgentChannel.singleton_class.alias_method(:disconnect, :original_disconnect)
    AgentChannel.singleton_class.remove_method(:original_disconnect)
  end
end
