using Test

const SHELL_ROOT = normpath(joinpath(@__DIR__, ".."))

@testset "locked shell contracts" begin
    bootstrap_path = joinpath(SHELL_ROOT, "scripts", "bootstrap_julia_env.sh")
    bootstrap_exists = isfile(bootstrap_path)
    @test bootstrap_exists
    if bootstrap_exists
        bootstrap = read(bootstrap_path, String)
        @test uperm(stat(bootstrap_path)) & 0o1 != 0
        @test occursin(
            "JULIA_DEPOT_PATH=\"\$ROOT/.julia-depot:/usr/local/share/julia:/usr/share/julia\"",
            bootstrap,
        )
        @test occursin("JULIA_LOAD_PATH='@:@stdlib'", bootstrap)
        @test occursin("JULIA_PKG_OFFLINE='false'", bootstrap)
        @test occursin("Project.toml", bootstrap)
        @test occursin("Manifest.toml", bootstrap)
        @test occursin("EMSx.jl/Project.toml", bootstrap)
        @test occursin("v\"1.12.6\"", bootstrap)
        pkg_calls = Set(match.match for match in eachmatch(r"Pkg\.[A-Za-z_]+", bootstrap))
        @test pkg_calls == Set(["Pkg.instantiate", "Pkg.precompile"])
        @test !occursin("master", lowercase(bootstrap))
        @test !occursin("write(", bootstrap)
    end

    locked_launcher = read(joinpath(SHELL_ROOT, "scripts", "julia_locked.sh"), String)
    @test occursin("JULIA_PKG_OFFLINE='true'", locked_launcher)

    sweep = read(joinpath(SHELL_ROOT, "experiments", "run_sweep.sh"), String)
    strict_mode = only(filter(line -> startswith(line, "set "), split(sweep, '\n')))
    @test strict_mode == "set -euo pipefail"

    bash = Sys.which("bash")
    @test !isnothing(bash)
    if !isnothing(bash)
        command = ignorestatus(Cmd([bash, "-c", "$(strict_mode); false | tee /dev/null"]))
        process = run(pipeline(command, stdout=devnull, stderr=devnull))
        @test process.exitcode != 0
    end
end
