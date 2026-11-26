class AgentTokensController < ApplicationController
  require_admin except: :index

  def index
    load_lists
  end

  def create
    @token = AgentToken.create!(params.expect(agent_token: [ :label, :fleet ]))
    Event.record("agent_token.created", subject: @token, summary: "Created agent token “#{@token.label}”")
    load_lists
    render :index, status: :created
  rescue ActiveRecord::RecordInvalid
    redirect_to agent_tokens_path, alert: "Give the token a label."
  end

  def destroy
    token = AgentToken.find(params[:id])
    token.revoke
    Event.record("agent_token.revoked", subject: token, summary: "Revoked agent token “#{token.label}”")
    redirect_to agent_tokens_path, notice: "Revoked. Agents using it are refused from now on."
  end

  private
    def load_lists
      @tokens = AgentToken.includes(:server).ordered
      @silent = Server.silent.ordered
      @never = Server.where(last_seen_at: nil).ordered
    end
end
