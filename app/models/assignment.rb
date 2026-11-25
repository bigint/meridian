# Git says this app should run on this server, in this role.
class Assignment < ApplicationRecord
  belongs_to :app
  belongs_to :server
end
