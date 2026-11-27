# System tests broadcast from the test process to the browser, which needs an
# adapter that works inside one process (the test one only records).
module AsyncCableHelper
  def use_async_cable
    @cable_config = ActionCable.server.config.cable
    ActionCable.server.config.cable = { "adapter" => "async" }
    ActionCable.server.restart
  end

  def restore_cable
    ActionCable.server.config.cable = @cable_config
    ActionCable.server.restart
  end
end
