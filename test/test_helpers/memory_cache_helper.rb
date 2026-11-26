# Tests run on a null cache. Throttles and leases need a real one.
module MemoryCacheHelper
  extend ActiveSupport::Concern

  included do
    setup { @original_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new }
    teardown { Rails.cache = @original_cache }
  end
end
