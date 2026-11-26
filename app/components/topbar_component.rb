# The bar above every page: search on the left, the person on the right, and
# on phones the button that opens the navigation drawer.
class TopbarComponent < ApplicationComponent
  def initialize(user:)
    @user = user
  end
end
