# Mission Control – Jobs is for admins only. Set here, not in after_initialize:
# its controllers read this when they are defined, and eager loading (CI,
# production) defines them before after_initialize runs.
MissionControl::Jobs.base_controller_class = "AdminController"
MissionControl::Jobs.http_basic_auth_enabled = false
