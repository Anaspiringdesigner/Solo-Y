module BiofeedbackSystem

include("config.jl")
include("types.jl")
include("auth.jl")
include("session_manager.jl")
include("redis_store.jl")
include("feature_service.jl")
include("rl_service.jl")
include("td_bridge_service.jl")
include("ingest_service.jl")
include("trigger_service.jl")
include("hardening.jl")
include("routes.jl")

using .Config
using .Types
using .Auth
using .SessionManager
using .RedisStore
using .FeatureService
using .RLService
using .TDBridgeService
using .IngestService
using .TriggerService
using .Hardening
using .Routes

end # module