# Sets environment variables for one block, then puts them back.
module EnvHelper
  def with_env(values)
    original = values.keys.to_h { [ it, ENV[it] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
