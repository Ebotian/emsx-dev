using Distributed
using Test
using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const PROJECT_FILE = joinpath(ROOT, "Project.toml")
const MANIFEST_FILE = joinpath(ROOT, "Manifest.toml")
const IDENTITY_FILE = joinpath(ROOT, "src", "EnvironmentIdentity.jl")
const EXPECTED_EMSX = realpath(joinpath(ROOT, "EMSx.jl", "src", "EMSx.jl"))
const EXPECTED_DEPOT = joinpath(ROOT, ".julia-depot")
const CURRENT_USER_DEPOT = joinpath(homedir(), ".julia")
const OTHER_USER_DEPOT = "/home/environment-identity-other-user/.julia"

@testset "locked root environment" begin
    project_exists = isfile(PROJECT_FILE)
    manifest_exists = isfile(MANIFEST_FILE)
    identity_exists = isfile(IDENTITY_FILE)
    @test project_exists
    @test manifest_exists
    @test identity_exists

    if project_exists && manifest_exists && identity_exists
        @eval using EMSx
        include(IDENTITY_FILE)
        @eval using .EnvironmentIdentity

        expected_project = realpath(PROJECT_FILE)
        expected_depot = realpath(EXPECTED_DEPOT)
        @test LOAD_PATH == ["@", "@stdlib"]
        @test DEPOT_PATH[1] == expected_depot
        @test EnvironmentIdentity.validate_depot_path!(ROOT, DEPOT_PATH) === nothing
        @test_throws ErrorException EnvironmentIdentity.validate_depot_path!(
            ROOT,
            [expected_depot, CURRENT_USER_DEPOT],
        )
        @test_throws ErrorException EnvironmentIdentity.validate_depot_path!(
            ROOT,
            [expected_depot, OTHER_USER_DEPOT],
        )
        normalized_workspace = joinpath(ROOT, "test", "..", ".julia-depot")
        @test EnvironmentIdentity.validate_depot_path!(
            ROOT,
            [normalized_workspace, "/usr/local/share/julia", "/usr/share/julia"],
        ) === nothing
        @test realpath(Base.active_project()) == expected_project
        @test realpath(pathof(EMSx)) == EXPECTED_EMSX

        manifest = TOML.parsefile(MANIFEST_FILE)
        @test manifest["julia_version"] == "1.12.6"
        entries = manifest["deps"]["EMSx"]
        entry = entries isa Vector ? only(entries) : entries
        @test entry["path"] == "EMSx.jl"

        @test EnvironmentIdentity.assert_environment!(ROOT) === nothing

        worker_ids = Int[]
        try
            worker_ids = EnvironmentIdentity.start_workers_checked!(ROOT, 2)
            @test length(worker_ids) == 2
            for worker in worker_ids
                identity = remotecall_fetch(worker) do
                    @eval using EMSx
                    (
                        load_path=copy(LOAD_PATH),
                        depot_path=copy(DEPOT_PATH),
                        project=realpath(Base.active_project()),
                        emsx=realpath(pathof(EMSx)),
                    )
                end
                @test identity.load_path == ["@", "@stdlib"]
                @test EnvironmentIdentity.validate_depot_path!(ROOT, identity.depot_path) ===
                      nothing
                @test identity.project == expected_project
                @test identity.emsx == EXPECTED_EMSX
            end
        finally
            isempty(worker_ids) || rmprocs(worker_ids)
        end

        @test nprocs() == 1
        mktempdir() do wrong_root
            @test_throws ErrorException EnvironmentIdentity.start_workers_checked!(wrong_root, 1)
        end
        @test nprocs() == 1

        cleanup_helper_exists =
            isdefined(EnvironmentIdentity, :_remove_workers_checked!)
        @test cleanup_helper_exists
        if cleanup_helper_exists
            worker_ids = EnvironmentIdentity.start_workers_checked!(ROOT, 1)
            rmprocs(worker_ids)
            @test EnvironmentIdentity._remove_workers_checked!(worker_ids) === nothing
            @test nprocs() == 1
        end

        scoped_helper_exists = isdefined(EnvironmentIdentity, :with_workers_checked)
        @test scoped_helper_exists
        if scoped_helper_exists
            @test EnvironmentIdentity.with_workers_checked(ROOT, 1) do worker_ids
                @test length(worker_ids) == 1
                @test nprocs() == 2
                return :success
            end == :success
            @test nprocs() == 1

            @test_throws ErrorException EnvironmentIdentity.with_workers_checked(ROOT, 1) do worker_ids
                @test length(worker_ids) == 1
                @test nprocs() == 2
                error("scoped worker failure")
            end
            @test nprocs() == 1
        end
    end
end
