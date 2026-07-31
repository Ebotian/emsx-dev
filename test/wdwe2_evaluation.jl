using CSV
using DataFrames
using SHA
using Statistics
using Test
using TOML

const EVALUATION_ROOT = normpath(joinpath(@__DIR__, ".."))
const EVALUATION_SCRIPT =
    joinpath(EVALUATION_ROOT, "scripts", "finalize_wdwe2_reproduction.jl")
const EVALUATION_BASELINE =
    joinpath(EVALUATION_ROOT, "baselines", "wdwe2_k20", "scores.csv")
const EXPECTED_WDWE2_MEAN = 0.7676755785921663

include(EVALUATION_SCRIPT)
using .WDWE2Reproduction

sha256_test_file(path::String) = bytes2hex(open(SHA.sha256, path))

function baseline_scores()
    return CSV.read(
        EVALUATION_BASELINE,
        DataFrame;
        stringtype=String,
        types=Dict(:site => String),
    )
end

function write_complete_run(
    path::String,
    phase::String,
    tag::String,
    run_id::String,
    artifacts::Dict{String,Vector{UInt8}},
    parameters::Dict{String,Any},
    root::String,
    config::Dict{String,Any};
    vf_manifest::Union{Nothing,String}=nothing,
)
    mkpath(path)
    for (relative, content) in artifacts
        output = joinpath(path, split(relative, '/')...)
        mkpath(dirname(output))
        write(output, content)
    end

    parameters["experiment_config"] = deepcopy(config)
    input_manifest = joinpath(root, config["inputs"]["input_manifest"])
    project = joinpath(root, "Project.toml")
    manifest = joinpath(root, "Manifest.toml")
    emsx = joinpath(root, "EMSx.jl", "src", "EMSx.jl")
    provenance = Dict{String,Any}(
        "schema_version" => 1,
        "captured_at_utc" => "2026-07-31T00:00:00",
        "phase" => phase,
        "tag" => tag,
        "run_id" => run_id,
        "julia_version" => string(VERSION),
        "cpu_name" => "test-cpu",
        "cpu_threads" => 1,
        "julia_threads" => 1,
        "blas_threads" => 1,
        "blas_config" => "test-blas",
        "active_project" => project,
        "emsx_path" => emsx,
        "load_path" => ["@", "@stdlib"],
        "outer_git_sha" => repeat("1", 40),
        "outer_git_dirty" => false,
        "nested_git_sha" => repeat("2", 40),
        "nested_git_dirty" => false,
        "project_sha256" => sha256_test_file(project),
        "manifest_sha256" => sha256_test_file(manifest),
        "input_manifest" => relpath(input_manifest, root),
        "input_manifest_sha256" => sha256_test_file(input_manifest),
        "vf_manifest" => vf_manifest === nothing ? "" : relpath(vf_manifest, root),
        "vf_manifest_sha256" =>
            vf_manifest === nothing ? "" : sha256_test_file(vf_manifest),
        "parameters" => parameters,
        "workers" => [
            Dict{String,Any}(
                "worker" => 2,
                "project" => project,
                "emsx" => emsx,
                "load_path" => ["@", "@stdlib"],
            ),
        ],
    )
    provenance_path = joinpath(path, "provenance.toml")
    open(provenance_path, "w") do io
        TOML.print(io, provenance; sorted=true)
    end

    manifest_path = joinpath(path, "artifacts.tsv")
    open(manifest_path, "w") do io
        println(io, "path\tbytes\tsha256")
        for relative in sort!(collect(keys(artifacts)))
            artifact = joinpath(path, split(relative, '/')...)
            println(
                io,
                join((relative, filesize(artifact), sha256_test_file(artifact)), '\t'),
            )
        end
    end

    status = Dict{String,Any}(
        "schema_version" => 1,
        "state" => "complete",
        "phase" => phase,
        "fingerprint" => WDWE2Reproduction.RunContract.fingerprint(parameters),
        "artifact_manifest" => "artifacts.tsv",
        "artifact_manifest_sha256" => sha256_test_file(manifest_path),
        "provenance_sha256" => sha256_test_file(provenance_path),
    )
    open(joinpath(path, "status.toml"), "w") do io
        TOML.print(io, status; sorted=true)
    end
    return path
end

function csv_bytes(frame::DataFrame)
    return mktempdir() do temp
        path = joinpath(temp, "frame.csv")
        CSV.write(path, frame)
        read(path)
    end
end

function make_finalizer_fixture(temp::String)
    tag = "local_wdwe2_k20_locked_v1"
    reuse_id = "reuse-existing-vf-v1"
    recalibrated_id = "recalibrated-v1"
    baseline_dir = joinpath(temp, "baselines", "wdwe2_k20")
    output_root = joinpath(temp, "results_sdp", "runs")
    legacy_vf_dir =
        joinpath(temp, "results_sdp", "sweep_wdwe2_k20", "value_functions")
    mkpath(baseline_dir)
    mkpath(legacy_vf_dir)

    expected = baseline_scores()
    baseline_scores_path = joinpath(baseline_dir, "scores.csv")
    CSV.write(baseline_scores_path, expected)

    legacy_manifest = joinpath(baseline_dir, "vf-manifest.tsv")
    open(legacy_manifest, "w") do io
        println(
            io,
            "site\tpath\tbytes\tsha256\thorizon\tsoc_points\tz_points\talpha_length\tbeta_length\tz_min\tz_max",
        )
        for site in 1:70
            relative = "results_sdp/sweep_wdwe2_k20/value_functions/$(site).jld2"
            path = joinpath(temp, split(relative, '/')...)
            write(path, "legacy-vf-$(site)")
            println(
                io,
                join(
                    (
                        site,
                        relative,
                        filesize(path),
                        sha256_test_file(path),
                        673,
                        11,
                        20,
                        672,
                        672,
                        -1.0,
                        1.0,
                    ),
                    '\t',
                ),
            )
        end
    end

    input_manifest = joinpath(baseline_dir, "input-manifest.tsv")
    write(input_manifest, "path\tbytes\tsha256\n")
    legacy_score = joinpath(temp, "results_sdp", "sweep_wdwe2_k20", "score.jld2")
    legacy_log = joinpath(temp, "results_sdp", "sweep_wdwe2_k20.log")
    write(legacy_score, "legacy-score")
    write(legacy_log, "legacy-log")
    legacy_contract_path = joinpath(baseline_dir, "legacy-source.toml")
    legacy_contract = Dict{String,Any}(
        "schema_version" => 1,
        "legacy_environment_lock" => "not_recorded_by_legacy_run",
        "legacy_score_path" => relpath(legacy_score, temp),
        "legacy_score_bytes" => filesize(legacy_score),
        "legacy_score_sha256" => sha256_test_file(legacy_score),
        "legacy_log_path" => relpath(legacy_log, temp),
        "legacy_log_bytes" => filesize(legacy_log),
        "legacy_log_sha256" => sha256_test_file(legacy_log),
        "value_function_directory" => relpath(legacy_vf_dir, temp),
        "value_function_count" => 70,
        "input_manifest_path" => relpath(input_manifest, temp),
        "input_manifest_sha256" => sha256_test_file(input_manifest),
        "scores_path" => relpath(baseline_scores_path, temp),
        "scores_sha256" => sha256_test_file(baseline_scores_path),
        "vf_manifest_path" => relpath(legacy_manifest, temp),
        "vf_manifest_sha256" => sha256_test_file(legacy_manifest),
    )
    open(legacy_contract_path, "w") do io
        TOML.print(io, legacy_contract; sorted=true)
    end

    write(joinpath(temp, "Project.toml"), "name = \"Task6Fixture\"\n")
    write(joinpath(temp, "Manifest.toml"), "julia_version = \"1.12.6\"\n")
    mkpath(joinpath(temp, "EMSx.jl", "src"))
    write(joinpath(temp, "EMSx.jl", "src", "EMSx.jl"), "module EMSx end\n")

    config_path = joinpath(temp, "wdwe2_k20.toml")
    config = Dict{String,Any}(
        "schema_version" => 1,
        "experiment" => Dict{String,Any}(
            "tag" => tag,
            "expected_sites" => 70,
        ),
        "parameters" => Dict{String,Any}("dx" => 0.1, "nz" => 20),
        "execution" => Dict{String,Any}("workers" => 1, "formal" => true),
        "inputs" => Dict{String,Any}(
            "input_manifest" => relpath(input_manifest, temp),
        ),
        "acceptance" => Dict{String,Any}(
            "expected_mean_score" => EXPECTED_WDWE2_MEAN,
            "mean_atol" => 1.0e-6,
            "site_atol" => 1.0e-6,
        ),
    )
    open(config_path, "w") do io
        TOML.print(io, config; sorted=true)
    end

    calibration = joinpath(output_root, tag, recalibrated_id, "calibrate")
    calibration_artifacts = Dict(
        "value_functions/$(site).jld2" =>
            Vector{UInt8}(codeunits("recalibrated-vf-$(site)")) for site in 1:70
    )
    write_complete_run(
        calibration,
        "calibrate",
        tag,
        recalibrated_id,
        calibration_artifacts,
        Dict{String,Any}(
            "phase" => "calibrate",
            "tag" => tag,
            "run_id" => recalibrated_id,
            "parameters" => deepcopy(config["parameters"]),
            "value_function_source_dir" => "",
            "value_function_manifest" => "",
            "simulation_source_dir" => "",
        ),
        temp,
        config,
    )

    paths = Dict{String,NamedTuple}()
    for (run_id, source_type) in (
        (reuse_id, "audited_legacy"),
        (recalibrated_id, "recalibrated"),
    )
        simulation = joinpath(output_root, tag, run_id, "simulate")
        simulation_artifacts = Dict(
            "$(site).jld2" => Vector{UInt8}(codeunits("simulation-$(site)")) for
            site in 1:70
        )
        simulation_artifacts["score.jld2"] = Vector{UInt8}(codeunits("score"))

        identity = if source_type == "audited_legacy"
            Dict{String,Any}(
                "type" => source_type,
                "source" => legacy_vf_dir,
                "manifest_sha256" => sha256_test_file(legacy_manifest),
                "legacy_contract_sha256" => sha256_test_file(legacy_contract_path),
                "value_function_count" => 70,
                "source_fingerprint" => sha256_test_file(legacy_manifest),
            )
        else
            calibration_status = TOML.parsefile(joinpath(calibration, "status.toml"))
            Dict{String,Any}(
                "type" => source_type,
                "source" => joinpath(calibration, "value_functions"),
                "run" => calibration,
                "source_fingerprint" => calibration_status["fingerprint"],
                "status_sha256" => sha256_test_file(joinpath(calibration, "status.toml")),
                "provenance_sha256" =>
                    sha256_test_file(joinpath(calibration, "provenance.toml")),
                "manifest_sha256" => sha256_test_file(
                    joinpath(calibration, "artifacts.tsv"),
                ),
                "value_function_count" => 70,
            )
        end
        vf_manifest = source_type == "audited_legacy" ?
                      legacy_manifest : joinpath(calibration, "artifacts.tsv")
        simulation_parameters = Dict{String,Any}(
            "phase" => "simulate",
            "tag" => tag,
            "run_id" => run_id,
            "parameters" => deepcopy(config["parameters"]),
            "value_function_source_dir" => identity["source"],
            "value_function_manifest" => vf_manifest,
            "simulation_source_dir" => "",
            "value_function_source_identity" => identity,
        )
        write_complete_run(
            simulation,
            "simulate",
            tag,
            run_id,
            simulation_artifacts,
            simulation_parameters,
            temp,
            config;
            vf_manifest=vf_manifest,
        )

        simulation_status = TOML.parsefile(joinpath(simulation, "status.toml"))
        evaluation = joinpath(output_root, tag, run_id, "evaluate")
        evaluation_parameters = Dict{String,Any}(
            "phase" => "evaluate",
            "tag" => tag,
            "run_id" => run_id,
            "parameters" => deepcopy(config["parameters"]),
            "value_function_source_dir" => "",
            "value_function_manifest" => "",
            "simulation_source_dir" => simulation,
            "simulation_source_identity" => Dict{String,Any}(
                "type" => "strict_complete_simulation",
                "source" => simulation,
                "source_fingerprint" => simulation_status["fingerprint"],
                "status_sha256" => sha256_test_file(joinpath(simulation, "status.toml")),
                "provenance_sha256" =>
                    sha256_test_file(joinpath(simulation, "provenance.toml")),
                "manifest_sha256" => sha256_test_file(
                    joinpath(simulation, "artifacts.tsv"),
                ),
                "artifact_count" => 71,
            ),
        )
        write_complete_run(
            evaluation,
            "evaluate",
            tag,
            run_id,
            Dict("metrics.csv" => csv_bytes(expected)),
            evaluation_parameters,
            temp,
            config,
        )
        paths[run_id] = (simulation=simulation, evaluation=evaluation)
    end

    return (
        tag=tag,
        reuse_id=reuse_id,
        recalibrated_id=recalibrated_id,
        baseline_dir=baseline_dir,
        output_root=output_root,
        config_path=config_path,
        legacy_manifest=legacy_manifest,
        legacy_contract=legacy_contract_path,
        calibration=calibration,
        paths=paths,
    )
end

@testset "wdwe2 score comparison" begin
    expected = baseline_scores()

    @testset "exact sites 1:70 pass" begin
        result = WDWE2Reproduction.compare_scores(copy(expected), expected)
        @test result.mean_passed
        @test result.all_sites_passed
        @test result.passed
    end

    @testset "one missing site fails" begin
        @test_throws ErrorException WDWE2Reproduction.compare_scores(
            expected[1:69, :],
            expected,
        )
    end

    @testset "non-finite tolerances fail closed" begin
        @test_throws ErrorException WDWE2Reproduction.compare_scores(
            expected,
            expected;
            site_atol=Inf,
        )
    end

    @testset "one duplicate site fails" begin
        actual = copy(expected)
        actual.site[end] = actual.site[end - 1]
        @test_throws ErrorException WDWE2Reproduction.compare_scores(actual, expected)
    end

    @testset "one site beyond tolerance fails" begin
        actual = copy(expected)
        actual.score[1] += 1.1e-6
        result = WDWE2Reproduction.compare_scores(actual, expected)
        @test !result.all_sites_passed
        @test !result.passed
    end

    @testset "cancelling site errors still fail" begin
        actual = copy(expected)
        actual.score[1] += 1.1e-6
        actual.score[2] -= 1.1e-6
        result = WDWE2Reproduction.compare_scores(actual, expected)
        @test result.mean_passed
        @test !result.all_sites_passed
        @test !result.passed
    end

    @testset "exact mean and all site errors within tolerance pass" begin
        actual = copy(expected)
        actual.score[1] += 0.5e-6
        actual.score[2] -= 0.5e-6
        result = WDWE2Reproduction.compare_scores(actual, expected)
        @test result.mean_passed
        @test result.all_sites_passed
        @test result.passed
    end
end

@testset "wdwe2 compact reproduction finalizer" begin
    mktempdir() do temp
        fixture = make_finalizer_fixture(temp)
        report_path, scores_path = WDWE2Reproduction.finalize_reproduction(
            root=temp,
            config_path=fixture.config_path,
            baseline_dir=fixture.baseline_dir,
            output_root=fixture.output_root,
            reuse_run_id=fixture.reuse_id,
            recalibrated_run_id=fixture.recalibrated_id,
        )

        report = TOML.parsefile(report_path)
        @test report["site_count"] == 70
        @test report["reuse_existing_vf_passed"] === true
        @test report["recalibrated_passed"] === true
        @test report["reuse_existing_vf_run_id"] == fixture.reuse_id
        @test report["recalibrated_run_id"] == fixture.recalibrated_id
        @test isapprox(
            report["recalibrated_mean_score"],
            EXPECTED_WDWE2_MEAN;
            atol=1.0e-6,
            rtol=0,
        )
        @test report["legacy_vf_manifest_sha256"] ==
              sha256_test_file(fixture.legacy_manifest)
        @test report["recalibrated_calibration_manifest_sha256"] ==
              sha256_test_file(joinpath(fixture.calibration, "artifacts.tsv"))

        reproduced = CSV.read(scores_path, DataFrame; stringtype=String)
        @test names(reproduced) == [
            "site",
            "legacy_score",
            "reuse_score",
            "recalibrated_score",
            "reuse_absolute_error",
            "recalibrated_absolute_error",
        ]
        @test reproduced.site == collect(1:70)
        @test all(reproduced.reuse_absolute_error .== 0.0)
        @test all(reproduced.recalibrated_absolute_error .== 0.0)

        before = Dict(
            report_path => read(report_path),
            scores_path => read(scores_path),
        )
        @test_throws ErrorException WDWE2Reproduction.finalize_reproduction(
            root=temp,
            config_path=fixture.config_path,
            baseline_dir=fixture.baseline_dir,
            output_root=fixture.output_root,
            reuse_run_id=fixture.reuse_id,
            recalibrated_run_id=fixture.recalibrated_id,
        )
        @test read(report_path) == before[report_path]
        @test read(scores_path) == before[scores_path]
    end
end

@testset "wdwe2 finalizer fails closed" begin
    mktempdir() do temp
        fixture = make_finalizer_fixture(temp)
        config = TOML.parsefile(fixture.config_path)
        config["acceptance"]["mean_atol"] = 1.0e-5
        config["acceptance"]["site_atol"] = 1.0e-5
        open(fixture.config_path, "w") do io
            TOML.print(io, config; sorted=true)
        end
        @test_throws ErrorException WDWE2Reproduction.finalize_reproduction(
            root=temp,
            config_path=fixture.config_path,
            baseline_dir=fixture.baseline_dir,
            output_root=fixture.output_root,
            reuse_run_id=fixture.reuse_id,
            recalibrated_run_id=fixture.recalibrated_id,
        )
    end

    mktempdir() do temp
        fixture = make_finalizer_fixture(temp)
        contract = TOML.parsefile(fixture.legacy_contract)
        contract["scores_sha256"] = repeat("0", 64)
        open(fixture.legacy_contract, "w") do io
            TOML.print(io, contract; sorted=true)
        end
        @test_throws ErrorException WDWE2Reproduction.finalize_reproduction(
            root=temp,
            config_path=fixture.config_path,
            baseline_dir=fixture.baseline_dir,
            output_root=fixture.output_root,
            reuse_run_id=fixture.reuse_id,
            recalibrated_run_id=fixture.recalibrated_id,
        )
    end

    mktempdir() do temp
        fixture = make_finalizer_fixture(temp)
        simulation = fixture.paths[fixture.reuse_id].simulation
        provenance_path = joinpath(simulation, "provenance.toml")
        provenance = TOML.parsefile(provenance_path)
        delete!(
            provenance["parameters"]["value_function_source_identity"],
            "legacy_contract_sha256",
        )
        open(provenance_path, "w") do io
            TOML.print(io, provenance; sorted=true)
        end
        status_path = joinpath(simulation, "status.toml")
        status = TOML.parsefile(status_path)
        status["fingerprint"] = WDWE2Reproduction.RunContract.fingerprint(
            Dict{String,Any}(
                String(key) => value for (key, value) in provenance["parameters"]
            ),
        )
        status["provenance_sha256"] = sha256_test_file(provenance_path)
        open(status_path, "w") do io
            TOML.print(io, status; sorted=true)
        end
        @test_throws ErrorException WDWE2Reproduction.finalize_reproduction(
            root=temp,
            config_path=fixture.config_path,
            baseline_dir=fixture.baseline_dir,
            output_root=fixture.output_root,
            reuse_run_id=fixture.reuse_id,
            recalibrated_run_id=fixture.recalibrated_id,
        )
    end

    mktempdir() do temp
        fixture = make_finalizer_fixture(temp)
        evaluation = fixture.paths[fixture.reuse_id].evaluation
        provenance_path = joinpath(evaluation, "provenance.toml")
        provenance = TOML.parsefile(provenance_path)
        provenance["outer_git_dirty"] = true
        open(provenance_path, "w") do io
            TOML.print(io, provenance; sorted=true)
        end
        status_path = joinpath(evaluation, "status.toml")
        status = TOML.parsefile(status_path)
        status["provenance_sha256"] = sha256_test_file(provenance_path)
        open(status_path, "w") do io
            TOML.print(io, status; sorted=true)
        end
        @test_throws ErrorException WDWE2Reproduction.finalize_reproduction(
            root=temp,
            config_path=fixture.config_path,
            baseline_dir=fixture.baseline_dir,
            output_root=fixture.output_root,
            reuse_run_id=fixture.reuse_id,
            recalibrated_run_id=fixture.recalibrated_id,
        )
    end

    mktempdir() do temp
        fixture = make_finalizer_fixture(temp)
        error_value = try
            WDWE2Reproduction.finalize_reproduction(
                root=temp,
                config_path=fixture.config_path,
                baseline_dir=fixture.baseline_dir,
                output_root=fixture.output_root,
                reuse_run_id="../escape",
                recalibrated_run_id=fixture.recalibrated_id,
            )
            nothing
        catch err
            err
        end
        @test error_value isa ErrorException
        @test occursin("invalid reuse RUN_ID", sprint(showerror, error_value))
    end
end
