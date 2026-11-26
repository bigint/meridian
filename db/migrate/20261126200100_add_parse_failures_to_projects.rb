# The head whose configs the parser couldn't read, and how many times in a
# row, so sync tries that head again with backoff instead of never or always.
class AddParseFailuresToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :parse_failed_sha, :string
    add_column :projects, :parse_failures, :integer, default: 0, null: false
  end
end
