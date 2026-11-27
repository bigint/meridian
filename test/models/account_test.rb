require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "there is always exactly one account" do
    assert_equal accounts(:main), Account.current

    Account.delete_all
    assert_difference -> { Account.count }, 1 do
      2.times { Account.current }
    end
  end

  test "a place is on the map only once it has both coordinates" do
    account = accounts(:main)
    assert_not account.located?

    account.latitude = 1.35
    assert_not account.located?

    account.longitude = 103.82
    assert account.located?
  end

  test "coordinates stay on the globe" do
    account = accounts(:main)

    account.latitude = 91
    account.longitude = -181
    assert_not account.valid?
    assert account.errors.include?(:latitude)
    assert account.errors.include?(:longitude)
  end
end
