class Project < ApplicationRecord
  include Changes, Syncable, WorkflowRuns

  has_many :apps, dependent: :destroy
  has_many :secret_names, dependent: :delete_all

  validates :name, :default_branch, presence: true
  validates :repo_full_name, presence: true, uniqueness: true, format: { with: %r{\A[\w.-]+/[\w.-]+\z}, message: "must look like owner/name" }
  validate :config_globs_present

  normalizes :config_globs, with: ->(globs) { Array(globs).flat_map { it.to_s.split(/[\s,]+/) }.compact_blank.uniq }

  # The Git host adapter for this project's repository.
  def git
    @git ||= GitHost.for(self)
  end

  def repo_url
    "https://github.com/#{repo_full_name}"
  end

  def config_errors?
    config_errors.any?
  end

  private
    def config_globs_present
      errors.add(:config_globs, "can't be blank") if config_globs.blank?
    end
end
