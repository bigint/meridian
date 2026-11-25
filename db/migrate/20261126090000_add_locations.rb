# Where servers are, and where Meridian itself runs, for the map.
class AddLocations < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :latitude, :float
    add_column :servers, :longitude, :float
    add_column :accounts, :latitude, :float
    add_column :accounts, :longitude, :float
    add_column :accounts, :location_name, :string
  end
end
