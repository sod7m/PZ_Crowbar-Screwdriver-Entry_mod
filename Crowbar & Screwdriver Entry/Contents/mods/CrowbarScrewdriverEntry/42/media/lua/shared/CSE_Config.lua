CSE_Config = {}

CSE_Config.MODULE_NAME = "CrowbarScrewdriverEntry"

CSE_Config.PRY_TIME = 300
CSE_Config.LOCKPICK_TIME = 180
CSE_Config.BOLT_CUT_TIME = 250

CSE_Config.BASE_NOISE_RADIUS = 10
CSE_Config.LOCKPICK_NOISE_RADIUS = 5
CSE_Config.BOLT_CUT_NOISE_RADIUS = 12

-- Baselines the sandbox multipliers scale from. A screwdriver is worked
-- gently, so it wears a fraction of what a crowbar or bolt cutter does.
CSE_Config.TOOL_DAMAGE_ON_FAIL = 2
CSE_Config.LOCKPICK_TOOL_DAMAGE_ON_FAIL = 1
CSE_Config.INJURY_DAMAGE = 5

-- No action drops below this many ticks, whatever the time multiplier is.
CSE_Config.MIN_ACTION_TIME = 30

CSE_Config.MAX_WORLD_INTERACT_DISTANCE = 2
CSE_Config.MAX_VEHICLE_INTERACT_DISTANCE = 3

CSE_Config.REQUEST_DEDUPE_WINDOW_MS = 2500

return CSE_Config
