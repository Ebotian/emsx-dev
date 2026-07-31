module EnvironmentIdentity

using Distributed
using EMSx
using TOML

export assert_environment!
export start_workers_checked!, with_workers_checked
export validate_depot_path!

normalized_depot_path(path::AbstractString) = normpath(abspath(expanduser(path)))

function canonical_depot_path(path::AbstractString)
    normalized = normalized_depot_path(path)
    return ispath(normalized) ? realpath(normalized) : normalized
end

function is_user_depot(path::AbstractString)
    normalized = normalized_depot_path(path)
    canonical = canonical_depot_path(path)
    return basename(normalized) == ".julia" || basename(canonical) == ".julia"
end

expected_project(root::String) = realpath(joinpath(root, "Project.toml"))
expected_emsx(root::String) = realpath(joinpath(root, "EMSx.jl", "src", "EMSx.jl"))
expected_depot(root::String) = canonical_depot_path(joinpath(root, ".julia-depot"))

function validate_depot_path!(root::String, depot_path::AbstractVector{<:AbstractString})
    isempty(depot_path) && error("DEPOT_PATH must not be empty")
    canonical = canonical_depot_path.(depot_path)
    canonical[1] == expected_depot(root) ||
        error("workspace depot must be first; got $(depot_path)")
    forbidden = filter(is_user_depot, depot_path)
    isempty(forbidden) || error("user depot detected: $(forbidden)")
    return nothing
end

function assert_environment!(root::String)
    LOAD_PATH == ["@", "@stdlib"] ||
        error("JULIA_LOAD_PATH must be @:@stdlib; got $(LOAD_PATH)")
    validate_depot_path!(root, DEPOT_PATH)
    realpath(Base.active_project()) == expected_project(root) ||
        error("wrong active Julia project")
    realpath(pathof(EMSx)) == expected_emsx(root) ||
        error("global EMSx fallback detected: $(pathof(EMSx))")

    manifest = TOML.parsefile(joinpath(root, "Manifest.toml"))
    manifest["julia_version"] == "1.12.6" || error("wrong Julia lock version")
    entries = manifest["deps"]["EMSx"]
    entry = entries isa Vector ? only(entries) : entries
    get(entry, "path", nothing) == "EMSx.jl" ||
        error("EMSx is not the relative local path dependency")
    return nothing
end

function _remove_workers_checked!(ids::AbstractVector{<:Integer})
    target = Set(Int.(ids))
    myid() in target && error("refusing to remove the main process")
    live = sort!(collect(intersect(target, Set(procs()))))
    if !isempty(live)
        try
            rmprocs(live)
        catch
            for worker in live
                worker in procs() || continue
                try
                    rmprocs(worker)
                catch
                end
            end
        end
    end
    remaining = sort!(collect(intersect(target, Set(procs()))))
    isempty(remaining) || error("failed to remove workers: $(remaining)")
    return nothing
end

function start_workers_checked!(root::String, count::Int)
    count > 0 || error("worker count must be positive")
    nprocs() == 1 || error("start with no pre-existing workers")
    project = dirname(Base.active_project())
    baseline = Set(procs())
    ids = Int[]

    try
        append!(
            ids,
            addprocs(
                count;
                exeflags=`--startup-file=no --history-file=no --project=$project`,
            ),
        )
        for worker in ids
            identity = remotecall_fetch(
                Core.eval,
                worker,
                Main,
                quote
                    using EMSx
                    (
                        load_path=copy(LOAD_PATH),
                        depot_path=copy(DEPOT_PATH),
                        project=realpath(Base.active_project()),
                        emsx=realpath(pathof(EMSx)),
                    )
                end,
            )
            identity.load_path == ["@", "@stdlib"] || error("unsafe worker LOAD_PATH")
            validate_depot_path!(root, identity.depot_path)
            identity.project == expected_project(root) || error("worker uses wrong project")
            identity.emsx == expected_emsx(root) || error("worker uses non-local EMSx")
        end
    catch startup_error
        started = sort!(unique(vcat(ids, collect(setdiff(Set(procs()), baseline)))))
        try
            _remove_workers_checked!(started)
        catch cleanup_error
            error(
                "worker startup failed ($(sprint(showerror, startup_error))); " *
                "cleanup failed ($(sprint(showerror, cleanup_error)))",
            )
        end
        rethrow()
    end
    return ids
end

function with_workers_checked(root::String, count::Int, f::Function)
    ids = start_workers_checked!(root, count)
    try
        applicable(f, ids) && return f(ids)
        applicable(f) && return f()
        throw(MethodError(f, (ids,)))
    finally
        _remove_workers_checked!(ids)
    end
end

with_workers_checked(f::Function, root::String, count::Int) =
    with_workers_checked(root, count, f)

end
