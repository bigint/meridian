# The schema once carried the old product name as the default, so databases
# loaded from it (every fresh install: db:prepare loads the schema) disagree
# with migrated ones. The literal below is that old name, kept to fix those rows.
class FixAccountNameDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :accounts, :name, from: "Alidade", to: "Meridian"
    up_only { execute "UPDATE accounts SET name = 'Meridian' WHERE name = 'Alidade'" }
  end
end
