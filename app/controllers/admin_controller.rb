# Base for admin-only screens, including Mission Control – Jobs.
class AdminController < ApplicationController
  require_admin
end
