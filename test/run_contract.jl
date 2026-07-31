using Test
using SHA
using TOML

const RUN_CONTRACT_ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(RUN_CONTRACT_ROOT, "src", "RunContract.jl"))
using .RunContract

function test_config(; phase::String="simulate", run_id::String="site-1")
    return Dict{String,Any}(
        "phase" => phase,
        "run_id" => run_id,
        "parameters" => Dict{String,Any}("dx" => 0.1, "k_noise" => 20),
    )
end

function incomplete_record(config::Dict)
    return Dict{String,Any}(
        "schema_version" => 1,
        "state" => "incomplete",
        "phase" => config["phase"],
        "fingerprint" => RunContract.fingerprint(config),
    )
end

function write_status(path::String, record::Dict{String,Any})
    open(joinpath(path, "status.toml"), "w") do io
        TOML.print(io, record; sorted=true)
    end
end

function write_artifacts(path::String)
    artifact_dir = joinpath(path, "artifacts")
    mkpath(artifact_dir)
    artifact = joinpath(artifact_dir, "result.csv")
    write(artifact, "site,score\n1,0.5\n")
    relative = "artifacts/result.csv"
    digest = bytes2hex(SHA.sha256(read(artifact)))
    manifest = joinpath(artifact_dir, "manifest.tsv")
    write(
        manifest,
        "path\tbytes\tsha256\n$(relative)\t$(filesize(artifact))\t$(digest)\n",
    )
    write(joinpath(path, "provenance.toml"), "schema_version = 1\nsource = \"test\"\n")
    return "artifacts/manifest.tsv"
end

function complete_record(config::Dict, manifest::String, path::String)
    return Dict{String,Any}(
        "schema_version" => 1,
        "state" => "complete",
        "phase" => config["phase"],
        "fingerprint" => RunContract.fingerprint(config),
        "artifact_manifest" => manifest,
        "artifact_manifest_sha256" => bytes2hex(SHA.sha256(read(joinpath(path, manifest)))),
        "provenance_sha256" => bytes2hex(SHA.sha256(read(joinpath(path, "provenance.toml")))),
    )
end

function reserve_new(path::String, config::Dict)
    return RunContract.with_run_lock(path) do lease
        RunContract.reserve_run!(lease, config)
    end
end

@testset "immutable run contract" begin
    config = test_config()

    @testset "fingerprint is canonical" begin
        reordered = Dict{String,Any}()
        reordered["parameters"] = Dict{String,Any}("k_noise" => 20, "dx" => 0.1)
        reordered["run_id"] = "site-1"
        reordered["phase"] = "simulate"
        @test RunContract.fingerprint(reordered) == RunContract.fingerprint(config)
    end

    @testset "new reservations publish an exact incomplete status" begin
        mktempdir() do temp
            path = joinpath(temp, "runs", "site-1")
            @test reserve_new(path, config) == :new
            @test TOML.parsefile(joinpath(path, "status.toml")) == incomplete_record(config)
            @test isfile(joinpath(dirname(path), ".site-1.lock"))
        end
    end

    @testset "sibling staging residue is outside the run and resume-safe" begin
        mktempdir() do temp
            path = joinpath(temp, "runs", "site-1")
            @test reserve_new(path, config) == :new

            staging = joinpath(dirname(path), ".emsx-task5-staging-$(basename(path))")
            mkpath(staging)
            residue = joinpath(staging, "crashed-status-temp")
            write(residue, "incomplete staging bytes\n")

            @test readdir(path) == ["status.toml"]
            @test RunContract.with_run_lock(path) do lease
                RunContract.reserve_run!(lease, config; resume=true)
            end == :resume
            @test read(residue, String) == "incomplete staging bytes\n"

            source = read(joinpath(RUN_CONTRACT_ROOT, "src", "RunContract.jl"), String)
            @test occursin(".emsx-task5-staging-", source)
            @test !occursin("mktemp(dirname(status_path))", source)
        end
    end

    @testset "a lease is nonblocking, process-exclusive, and released" begin
        mktempdir() do temp
            path = joinpath(temp, "run")
            child = joinpath(temp, "hold_lock.jl")
            release = joinpath(temp, "release")
            write(
                child,
                """
                include($(repr(joinpath(RUN_CONTRACT_ROOT, "src", "RunContract.jl"))))
                using .RunContract
                RunContract.with_run_lock(ARGS[1]) do _
                    println("locked")
                    flush(stdout)
                    while !isfile(ARGS[2])
                        sleep(0.01)
                    end
                end
                """,
            )
            holder = open(
                `$(joinpath(RUN_CONTRACT_ROOT, "scripts", "julia_locked.sh")) $child $path $release`,
                "r",
            )
            try
                @test readline(holder) == "locked"
                @test_throws ErrorException RunContract.with_run_lock(path) do _
                    nothing
                end
                write(release, "release\n")
                wait(holder)
            finally
                isfile(release) || write(release, "release\n")
                close(holder)
            end
            @test RunContract.with_run_lock(path) do lease
                lease !== nothing
            end
            @test_throws ErrorException RunContract.with_run_lock(path) do _
                error("callback failure")
            end
            @test RunContract.with_run_lock(path) do _
                true
            end
        end
    end

    @testset "only the same strict incomplete record resumes" begin
        mktempdir() do temp
            path = joinpath(temp, "run")
            @test reserve_new(path, config) == :new
            @test RunContract.with_run_lock(path) do lease
                RunContract.reserve_run!(lease, config; resume=true)
            end == :resume

            changed = test_config(run_id="site-2")
            @test_throws ErrorException RunContract.with_run_lock(path) do lease
                RunContract.reserve_run!(lease, changed; resume=true)
            end
        end
    end

    @testset "strict status schemas reject malformed records" begin
        mktempdir() do temp
            valid = incomplete_record(config)
            malformed = Dict{String,Any}[
                Dict("state" => "incomplete", "phase" => "simulate", "fingerprint" => valid["fingerprint"]),
                merge(valid, Dict("extra" => true)),
                merge(valid, Dict("schema_version" => "1")),
                merge(valid, Dict("state" => 1)),
                merge(valid, Dict("state" => "pending")),
                merge(valid, Dict("phase" => 1)),
                merge(valid, Dict("phase" => "unknown")),
                merge(valid, Dict("fingerprint" => uppercase(valid["fingerprint"]))),
                merge(valid, Dict("fingerprint" => "not-a-sha256")),
            ]
            for (index, record) in enumerate(malformed)
                path = joinpath(temp, "incomplete-$(index)")
                mkdir(path)
                write_status(path, record)
                @test_throws ErrorException RunContract.with_run_lock(path) do lease
                    RunContract.reserve_run!(lease, config; resume=true)
                end
            end

            complete_path = joinpath(temp, "complete")
            mkdir(complete_path)
            manifest = write_artifacts(complete_path)
            valid_complete = complete_record(config, manifest, complete_path)
            malformed_complete = Dict{String,Any}[
                Dict("schema_version" => 1, "state" => "complete", "phase" => "simulate", "fingerprint" => valid["fingerprint"]),
                merge(valid_complete, Dict("extra" => true)),
                merge(valid_complete, Dict("artifact_manifest" => 1)),
                merge(valid_complete, Dict("artifact_manifest" => "../manifest.tsv")),
                merge(valid_complete, Dict("artifact_manifest_sha256" => uppercase(valid_complete["artifact_manifest_sha256"]))),
                merge(valid_complete, Dict("provenance_sha256" => "short")),
            ]
            for record in malformed_complete
                write_status(complete_path, record)
                @test_throws ErrorException RunContract.assert_complete!(complete_path; phase="simulate")
            end
        end
    end

    @testset "existing crash residue is never overwritten" begin
        mktempdir() do temp
            residues = [
                ("missing", nothing),
                ("truncated", "schema_version = 1\nstate = \"incomplete\"\n"),
                ("invalid", "this is not valid TOML = [\n"),
            ]
            for (name, contents) in residues
                path = joinpath(temp, name)
                mkdir(path)
                status_path = joinpath(path, "status.toml")
                contents === nothing || write(status_path, contents)
                before = isfile(status_path) ? read(status_path, String) : nothing
                @test_throws Exception RunContract.with_run_lock(path) do lease
                    RunContract.reserve_run!(lease, config)
                end
                @test isdir(path)
                @test (isfile(status_path) ? read(status_path, String) : nothing) == before
            end
        end
    end

    @testset "completion is lease-scoped and hash-bound" begin
        mktempdir() do temp
            path = joinpath(temp, "run")
            manifest = Ref{String}("")
            expired_lease = Ref{Any}(nothing)
            RunContract.with_run_lock(path) do lease
                @test RunContract.reserve_run!(lease, config) == :new
                manifest[] = write_artifacts(path)
                changed = test_config(phase="calibrate")
                @test_throws ErrorException RunContract.mark_complete!(
                    lease,
                    changed;
                    artifact_manifest=manifest[],
                )
                @test TOML.parsefile(joinpath(path, "status.toml")) == incomplete_record(config)
                @test RunContract.mark_complete!(lease, config; artifact_manifest=manifest[]) === nothing
                record = RunContract.assert_complete!(path; phase="simulate")
                @test record == complete_record(config, manifest[], path)
                @test_throws ErrorException RunContract.assert_complete!(path; phase="calibrate")
                @test_throws ErrorException RunContract.mark_complete!(
                    lease,
                    config;
                    artifact_manifest=manifest[],
                )
                expired_lease[] = lease
            end
            @test_throws ErrorException RunContract.mark_complete!(
                expired_lease[],
                config;
                artifact_manifest=manifest[],
            )
            rebound = joinpath(temp, "rebound")
            @test_throws Exception begin
                setfield!(expired_lease[], :active, true)
                setfield!(expired_lease[], :path, rebound)
                RunContract.reserve_run!(expired_lease[], config)
            end
            @test !ispath(rebound)
            write(joinpath(path, manifest[]), "changed manifest\n")
            @test_throws ErrorException RunContract.assert_complete!(path; phase="simulate")
        end
    end

    @testset "fake completion and mutable provenance are rejected" begin
        mktempdir() do temp
            fake = joinpath(temp, "fake")
            mkdir(fake)
            write_status(fake, Dict("schema_version" => 1, "state" => "complete", "phase" => "simulate", "fingerprint" => RunContract.fingerprint(config)))
            @test_throws ErrorException RunContract.assert_complete!(fake; phase="simulate")

            path = joinpath(temp, "run")
            RunContract.with_run_lock(path) do lease
                RunContract.reserve_run!(lease, config)
                manifest = write_artifacts(path)
                RunContract.mark_complete!(lease, config; artifact_manifest=manifest)
            end
            write(joinpath(path, "provenance.toml"), "changed provenance\n")
            @test_throws ErrorException RunContract.assert_complete!(path; phase="simulate")
        end
    end

    @testset "completion validates every artifact manifest entry" begin
        for mutation in (:tampered, :missing, :symlink, :bad_row)
            mktempdir() do temp
                path = joinpath(temp, "run-$(mutation)")
                RunContract.with_run_lock(path) do lease
                    RunContract.reserve_run!(lease, config)
                    manifest = write_artifacts(path)
                    artifact = joinpath(path, "artifacts", "result.csv")
                    if mutation == :tampered
                        write(artifact, "changed\n")
                    elseif mutation == :missing
                        rm(artifact)
                    elseif mutation == :symlink
                        outside = joinpath(temp, "outside.csv")
                        cp(artifact, outside)
                        rm(artifact)
                        symlink(outside, artifact)
                    else
                        write(
                            joinpath(path, manifest),
                            "path\tbytes\tsha256\nartifacts/result.csv\tbad\tdeadbeef\n",
                        )
                    end
                    @test_throws ErrorException RunContract.mark_complete!(
                        lease,
                        config;
                        artifact_manifest=manifest,
                    )
                    @test TOML.parsefile(joinpath(path, "status.toml")) ==
                          incomplete_record(config)
                end
            end
        end
    end

    @testset "assert_complete revalidates artifact bytes and paths" begin
        for mutation in (:tampered, :missing, :symlink, :bad_row)
            mktempdir() do temp
                path = joinpath(temp, "run-$(mutation)")
                manifest = Ref{String}("")
                RunContract.with_run_lock(path) do lease
                    RunContract.reserve_run!(lease, config)
                    manifest[] = write_artifacts(path)
                    RunContract.mark_complete!(
                        lease,
                        config;
                        artifact_manifest=manifest[],
                    )
                end
                artifact = joinpath(path, "artifacts", "result.csv")
                if mutation == :tampered
                    write(artifact, "changed\n")
                elseif mutation == :missing
                    rm(artifact)
                elseif mutation == :symlink
                    outside = joinpath(temp, "outside.csv")
                    cp(artifact, outside)
                    rm(artifact)
                    symlink(outside, artifact)
                else
                    manifest_path = joinpath(path, manifest[])
                    write(
                        manifest_path,
                        "path\tbytes\tsha256\nartifacts/result.csv\tbad\tdeadbeef\n",
                    )
                    status = TOML.parsefile(joinpath(path, "status.toml"))
                    status["artifact_manifest_sha256"] =
                        bytes2hex(SHA.sha256(read(manifest_path)))
                    write_status(path, status)
                end
                @test_throws ErrorException RunContract.assert_complete!(
                    path;
                    phase="simulate",
                )
            end
        end
    end

    @testset "completion rejects a symlinked artifact manifest" begin
        mktempdir() do temp
            path = joinpath(temp, "run")
            RunContract.with_run_lock(path) do lease
                RunContract.reserve_run!(lease, config)
                write(joinpath(temp, "outside.tsv"), "outside\n")
                mkpath(joinpath(path, "artifacts"))
                symlink(joinpath(temp, "outside.tsv"), joinpath(path, "artifacts", "manifest.tsv"))
                write(joinpath(path, "provenance.toml"), "source = \"test\"\n")
                @test_throws ErrorException RunContract.mark_complete!(
                    lease,
                    config;
                    artifact_manifest="artifacts/manifest.tsv",
                )
            end
        end
    end

    @testset "path components reject traversal" begin
        for name in ("TAG", "RUN_ID")
            @test RunContract.validate_component("local_wdwe2-k20.v1", name) ==
                  "local_wdwe2-k20.v1"
            for invalid in ("", "../legacy", "a/b", "a\\b", ".", "..", "with space")
                @test_throws ErrorException RunContract.validate_component(invalid, name)
            end
        end
    end
end
