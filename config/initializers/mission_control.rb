# Mission Control – Jobs sits behind Meridian's sign-in. Set here, not in
# after_initialize: its controllers read this when they are defined, and eager
# loading (CI, production) defines them before after_initialize runs.
MissionControl::Jobs.base_controller_class = "ApplicationController"
MissionControl::Jobs.http_basic_auth_enabled = false
