class Project < ApplicationRecord
  include Changes, Syncable, WorkflowRuns

  has_many :apps, dependent: :destroy
  has_many :secret_names, dependent: :delete_all

  validates :name, :default_branch, presence: true
  validates :repo_full_name, presence: true, uniqueness: { case_sensitive: false }, format: { with: %r{\A[\w.-]+/[\w.-]+\z}, message: "must look like owner/name" }
  validate :config_globs_present

  normalizes :config_globs, with: ->(globs) { Array(globs).flat_map { it.to_s.split(/[\s,]+/) }.compact_blank.uniq }

  # GitHub names repositories without regard to case, and its webhooks use
  # its own spelling, which may differ from the one typed in.
  def self.for_repo(full_name)
    find_by("LOWER(repo_full_name) = ?", full_name.to_s.downcase)
  end

  # The Git host adapter for this project's repository.
  def git
    @git ||= GitHost.for(self)
  end

  def repo_url = git.repo_url

  # Where a new config for this service goes: the first config glob with one
  # "*", which the service replaces ("deploy/**/*.yml" counts as
  # "deploy/*.yml").
  def config_path_for(service)
    glob = Array(config_globs).map { it.gsub("**/", "") }.find { it.count("*") == 1 }
    prefix, suffix = (glob || "config/deploy*.yml").split("*", 2)
    separator = prefix.empty? || prefix.end_with?("/", ".", "-", "_") ? "" : "-"
    "#{prefix}#{separator}#{service}#{suffix}"
  end

  def config_errors?
    config_errors.any?
  end

  private
    def config_globs_present
      errors.add(:config_globs, "can't be blank") if config_globs.blank?
    end
end
