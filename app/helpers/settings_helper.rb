# What Meridian is connected to, read from the environment for Settings.
module SettingsHelper
  Connection = Data.define(:icon, :name, :status, :tone, :detail, :mono)

  def connections
    [ github_connection, kamal_connection ]
  end

  private
    def github_connection
      github = GitHost::GitHub
      if github.token_mode?
        Connection.new(icon: :git_host, name: "GitHub", status: "Token", tone: nil, mono: false,
          detail: safe_join([ "A personal access token from ", env_var("GITHUB_TOKEN"), ". A GitHub App limits access to the repositories you pick." ]))
      elsif github.configured?
        Connection.new(icon: :git_host, name: "GitHub", status: "App #{github.app_id}", tone: :ok, mono: false,
          detail: safe_join([ "Signed in as the App from ", env_var("GITHUB_APP_ID"), " and its private key." ]))
      else
        Connection.new(icon: :git_host, name: "GitHub", status: "Not connected", tone: :bad, mono: false,
          detail: safe_join([ "Set ", env_var("GITHUB_TOKEN"), ", or ", env_var("GITHUB_APP_ID"), " and ", env_var("GITHUB_APP_PRIVATE_KEY"), "." ]))
      end
    end

    def kamal_connection
      Connection.new(icon: :kamal, name: "Kamal", status: KamalConfig::KAMAL_VERSION, tone: nil, mono: true,
        detail: "Reads your configs here, and runs your deploys in CI.")
    end

    def env_var(name) = tag.code(name)
end
