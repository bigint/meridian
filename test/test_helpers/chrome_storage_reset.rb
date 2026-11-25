# Capybara 3.40 resets sessions with Storage.clearDataForOrigin(origin: "*"),
# which Chrome 15x rejects. Clear cookies directly instead; local storage is
# not used by Meridian.
require "capybara/selenium/driver"
require "capybara/selenium/driver_specializations/chrome_driver"

Capybara::Selenium::Driver::ChromeDriver.prepend(Module.new do
  private
    def execute_cdp(cmd, params = {})
      if cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"
        super("Network.clearBrowserCookies")
      else
        super
      end
    end
end)
