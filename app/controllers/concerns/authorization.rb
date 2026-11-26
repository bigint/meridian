module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_user
  end

  private
    def current_user
      Current.user
    end
end
