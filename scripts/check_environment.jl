using Distributed
using EMSx

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "EnvironmentIdentity.jl"))
using .EnvironmentIdentity

function identity_snapshot()
    return (
        project=realpath(Base.active_project()),
        emsx=realpath(pathof(EMSx)),
        load_path=copy(LOAD_PATH),
        depot_path=copy(DEPOT_PATH),
    )
end

EnvironmentIdentity.assert_environment!(ROOT)
println("main identity: ", identity_snapshot())
count = parse(Int, get(ENV, "N_WORKERS", "2"))
worker_ids = EnvironmentIdentity.start_workers_checked!(ROOT, count)
for worker in worker_ids
    identity = remotecall_fetch(worker) do
        @eval using EMSx
        (
            project=realpath(Base.active_project()),
            emsx=realpath(pathof(EMSx)),
            load_path=copy(LOAD_PATH),
            depot_path=copy(DEPOT_PATH),
        )
    end
    println("worker $(worker) identity: ", identity)
end
println("verified local EMSx for main process and $(count) workers")
