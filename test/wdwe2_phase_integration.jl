using CSV
using DataFrames
using Dates
using Distributed
using EMSx
using JLD2
using SHA
using StoOpt
using Test
using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const RUNNER = joinpath(ROOT, "sdp_ar1_wdwe2.jl")
const LOCKED_JULIA = joinpath(ROOT, "scripts", "julia_locked.sh")
const FORMAL_CONFIG = joinpath(ROOT, "configs", "wdwe2_k20.toml")
const FORMAL_INPUT_MANIFEST =
    joinpath(ROOT, "baselines", "wdwe2_k20", "input-manifest.tsv")
const LEGACY_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20")
const LEGACY_HELPER = joinpath(ROOT, "EMSx.jl", "examples", "sdp", "function.jl")
const TEST_TAG = "task5_one_site"
const TEST_RUN_ID = "real-child-chain"

include(joinpath(ROOT, "src", "Provenance.jl"))
include(joinpath(ROOT, "src", "RunContract.jl"))
using .Provenance
using .RunContract

sha256_file(path::String) = bytes2hex(open(SHA.sha256, path))

function recursive_files(root::String)
    isdir(root) || return String[]
    files = String[]
    for (directory, _, names) in walkdir(root)
        append!(files, joinpath.(Ref(directory), names))
    end
    sort!(files)
    return files
end

function content_snapshot(paths::Vector{String})
    return Dict(
        path => (
            bytes=filesize(path),
            modified=stat(path).mtime,
            sha256=sha256_file(path),
        ) for path in paths
    )
end

function formal_input_stat_snapshot()
    rows = Iterators.drop(readlines(FORMAL_INPUT_MANIFEST), 1)
    paths = [joinpath(ROOT, split(row, '\t'; keepempty=true)[1]) for row in rows]
    return Dict(
        path => (bytes=filesize(path), modified=stat(path).mtime) for path in paths
    )
end

function write_one_site_fixture(temp::String)
    fixture_root = joinpath(temp, "fixture")
    train_dir = joinpath(fixture_root, "train")
    test_dir = joinpath(fixture_root, "test")
    mkpath(train_dir)
    mkpath(test_dir)

    prices = joinpath(fixture_root, "prices.csv")
    cp(joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv"), prices)

    metadata = joinpath(fixture_root, "metadata.csv")
    CSV.write(
        metadata,
        DataFrame(
            site_id=[1],
            max_load=[10.0],
            capacity=[20.0],
            power=[5.0],
            charge_efficiency=[0.95],
            discharge_efficiency=[0.95],
        ),
    )

    indices = collect(0:1343)
    train = DataFrame(
        actual_consumption=10.0 .+ sin.(2pi .* (indices .% 96) ./ 96) .+
                           0.01 .* (indices .÷ 672),
        actual_pv=2.0 .+ 0.5 .* cos.(2pi .* (indices .% 96) ./ 96),
    )
    EMSx.write_site_file(joinpath(train_dir, "1.csv"), train)

    rows = 97
    test = DataFrame(
        timestamp=DateTime(2026, 1, 1) .+ Minute(15) .* collect(0:(rows - 1)),
        site_id=fill(1, rows),
        period_id=fill(1, rows),
        actual_consumption=fill(10.0, rows),
        actual_pv=fill(2.0, rows),
    )
    for index in 0:95
        test[!, Symbol("load_$(lpad(index, 2, '0'))")] = fill(10.0, rows)
        test[!, Symbol("pv_$(lpad(index, 2, '0'))")] = fill(2.0, rows)
    end
    EMSx.write_site_file(joinpath(test_dir, "1.csv"), test)

    train_file = joinpath(train_dir, "1.csv.gz")
    test_file = joinpath(test_dir, "1.csv.gz")
    input_manifest = joinpath(fixture_root, "input-manifest.tsv")
    Provenance.write_file_manifest(
        input_manifest,
        [
            joinpath(ROOT, "EMSx.jl", "metadata", "baseline", "anticipative.jld2"),
            joinpath(ROOT, "EMSx.jl", "metadata", "baseline", "dummy.jld2"),
            prices,
            metadata,
            train_file,
            test_file,
        ],
        ROOT,
    )

    return (
        root=fixture_root,
        prices=prices,
        metadata=metadata,
        train=train_dir,
        test=test_dir,
        train_file=train_file,
        test_file=test_file,
        input_manifest=input_manifest,
    )
end

function write_test_config(
    path::String,
    fixture,
    output_root::String;
    development_settings::Dict{String,Any}=Dict{String,Any}(),
)
    development = Dict{String,Any}("output_root" => output_root)
    merge!(development, development_settings)
    config = Dict{String,Any}(
        "schema_version" => 1,
        "experiment" => Dict{String,Any}(
            "controller" => "wdwe2_periodic_ar1",
            "tag" => TEST_TAG,
            "seed" => 20260731,
            "expected_sites" => 1,
        ),
        "parameters" => Dict{String,Any}(
            "dx" => 0.1,
            "du" => 1.0,
            "k_noise" => 1,
            "margin" => 0.5,
            "nz" => 20,
            "horizon" => 672,
            "max_vi_iters" => 0,
            "vi_tol" => 0.001,
        ),
        "execution" => Dict{String,Any}("workers" => 1, "formal" => false),
        "inputs" => Dict{String,Any}(
            "input_manifest" => fixture.input_manifest,
            "prices" => fixture.prices,
            "metadata" => fixture.metadata,
            "train" => fixture.train,
            "test" => fixture.test,
        ),
        "development" => development,
        "acceptance" => Dict{String,Any}(
            "expected_mean_score" => 0.7676755785921663,
            "mean_atol" => 1.0e-6,
            "site_atol" => 1.0e-6,
        ),
    )
    open(path, "w") do io
        TOML.print(io, config; sorted=true)
    end
    return config
end

phase_output(output_root::String, run_id::String, phase::String) =
    joinpath(output_root, TEST_TAG, run_id, phase)

function child_environment(
    config_path::String,
    phase::String,
    run_id::String;
    vf_source::String="",
    vf_manifest::String="",
    simulation_source::String="",
    run_output::String="",
    resume::Bool=false,
)
    return Dict(
        "EXPERIMENT_CONFIG" => config_path,
        "PHASE" => phase,
        "RUN_ID" => run_id,
        "RUN_OUTPUT_DIR" => run_output,
        "VALUE_FUNCTION_SOURCE_DIR" => vf_source,
        "VALUE_FUNCTION_MANIFEST" => vf_manifest,
        "SIMULATION_SOURCE_DIR" => simulation_source,
        "RESUME_INCOMPLETE" => string(resume),
    )
end

function phase_command(config_path::String, phase::String, run_id::String; kwargs...)
    return addenv(
        `$LOCKED_JULIA $RUNNER`,
        child_environment(config_path, phase, run_id; kwargs...),
    )
end

function run_phase(
    config_path::String,
    phase::String,
    run_id::String;
    expect_success::Bool=true,
    expected_error::Union{Nothing,String}=nothing,
    kwargs...,
)
    output = IOBuffer()
    process = run(
        pipeline(
            phase_command(config_path, phase, run_id; kwargs...);
            stdout=output,
            stderr=output,
        );
        wait=false,
    )
    wait(process)
    text = String(take!(output))
    if expect_success
        success(process) || error(
            "locked child $(phase) main failed with exit $(process.exitcode):\n$(text)",
        )
        expected_error === nothing || error("success case supplied expected_error")
    else
        expected_error === nothing && error("negative child case must name expected_error")
        success(process) && error("locked child $(phase) main unexpectedly succeeded")
        occursin(expected_error, text) || error(
            "locked child $(phase) failure did not contain $(repr(expected_error)):\n$(text)",
        )
    end
    return text
end

function start_phase(config_path::String, phase::String, run_id::String; kwargs...)
    output = IOBuffer()
    process = run(
        pipeline(
            phase_command(config_path, phase, run_id; kwargs...);
            stdout=output,
            stderr=output,
        );
        wait=false,
    )
    return (process=process, output=output, phase=phase)
end

function finish_phase(child; expect_success::Bool, expected_error::Union{Nothing,String}=nothing)
    wait(child.process)
    text = String(take!(child.output))
    if expect_success
        success(child.process) || error(
            "background child $(child.phase) failed with exit $(child.process.exitcode):\n$(text)",
        )
    else
        expected_error === nothing && error("negative background case needs expected_error")
        success(child.process) && error("background child unexpectedly succeeded")
        occursin(expected_error, text) || error(
            "background child failure did not contain $(repr(expected_error)):\n$(text)",
        )
    end
    return text
end

function wait_until(predicate::Function, label::String; timeout::Float64=60.0)
    deadline = time() + timeout
    while time() < deadline
        predicate() && return nothing
        sleep(0.05)
    end
    error("timed out waiting for $(label)")
end

function copy_run_source(source::String, target::String)
    ispath(target) && error("copy target exists: $(target)")
    mkpath(dirname(target))
    cp(source, target)
    return target
end

function assert_strict_complete(path::String, phase::String, expected_artifacts::Set{String})
    status = RunContract.assert_complete!(path; phase=phase)
    @test Set(keys(status)) == Set((
        "schema_version",
        "state",
        "phase",
        "fingerprint",
        "artifact_manifest",
        "artifact_manifest_sha256",
        "provenance_sha256",
    ))
    @test status["state"] == "complete"
    @test status["phase"] == phase
    @test status["artifact_manifest"] == "artifacts.tsv"

    manifest = joinpath(path, status["artifact_manifest"])
    snapshot = Provenance.capture_manifest_snapshot(manifest, path)
    @test Set(entry.path for entry in snapshot.entries) == expected_artifacts
    @test snapshot.manifest_sha256 == status["artifact_manifest_sha256"]
    Provenance.verify_manifest_snapshot(snapshot)
    return status
end

runner_source = read(RUNNER, String)
formal_config = TOML.parsefile(FORMAL_CONFIG)

function run_static_contract_tests()
    @testset "wdwe2 phase runner static contract" begin
        @test occursin("RunContract.with_run_lock", runner_source)
        @test occursin("EnvironmentIdentity.with_workers_checked", runner_source)
        @test occursin("Provenance.capture_manifest_snapshot", runner_source)
        @test occursin("Provenance.verify_manifest_snapshot", runner_source)
        @test !occursin("EMSx.group_all_simulations(sites)", runner_source)
        @test !occursin("EMSx.save_simulations", runner_source)
        @test occursin("abspath(PROGRAM_FILE) == (@__FILE__) && main()", runner_source)
        @test occursin("legacy-source.toml", runner_source)
        @test occursin(
            "site\\tpath\\tbytes\\tsha256\\thorizon\\tsoc_points\\tz_points\\talpha_length\\tbeta_length\\tz_min\\tz_max",
            runner_source,
        )
        @test occursin("value_function_source_identity", runner_source)
        @test occursin("simulation_source_identity", runner_source)
        @test occursin("verify_after_worker_cleanup!", runner_source)
        @test findlast("RunContract.mark_complete!", runner_source) >
              findlast("verify_after_worker_cleanup!", runner_source)
        @test occursin("formal configurations must not contain development settings", runner_source)
        @test occursin(".emsx-task5-staging-", runner_source)
        @test !occursin("mktemp(dirname(output))", runner_source)
        @test !occursin("with_private_temp(dirname(output))", runner_source)
        @test !occursin("with_private_temp(path_to_save_folder)", runner_source)
        @test !occursin("with_private_temp(evaluation_output)", runner_source)

        @test formal_config["execution"]["formal"] === true
        @test haskey(formal_config, "inputs")
        @test Set(keys(formal_config["inputs"])) ==
              Set(("input_manifest", "prices", "metadata", "train", "test"))
        @test !haskey(formal_config, "development")
    end
end

@testset "wdwe2 real locked child phase chain" begin
    legacy_paths = recursive_files(LEGACY_DIR)
    protected_paths = vcat(legacy_paths, [LEGACY_HELPER, FORMAL_INPUT_MANIFEST])
    protected_before = content_snapshot(protected_paths)
    formal_inputs_before = formal_input_stat_snapshot()

    mktempdir(ROOT; prefix=".task5-phase-test-") do temp
        fixture = write_one_site_fixture(temp)
        output_root = joinpath(temp, "outputs")
        config_path = joinpath(temp, "one-site.toml")
        config = write_test_config(config_path, fixture, output_root)
        input_snapshot =
            Provenance.capture_manifest_snapshot(fixture.input_manifest, ROOT)
        config_guard = Provenance.capture_stable_file_guard(config_path, ROOT)
        fixture_before = content_snapshot([
            fixture.prices,
            fixture.metadata,
            fixture.train_file,
            fixture.test_file,
            fixture.input_manifest,
        ])

        calibration_output = phase_output(output_root, TEST_RUN_ID, "calibrate")
        simulation_output = phase_output(output_root, TEST_RUN_ID, "simulate")
        evaluation_output = phase_output(output_root, TEST_RUN_ID, "evaluate")

        malformed_config = deepcopy(config)
        malformed_config["execution"]["formal"] = 0
        malformed_config_path = joinpath(temp, "malformed-formal.toml")
        open(malformed_config_path, "w") do io
            TOML.print(io, malformed_config; sorted=true)
        end
        run_phase(
            malformed_config_path,
            "calibrate",
            "malformed-formal";
            expect_success=false,
            expected_error="execution.formal must be a Bool",
        )
        @test !ispath(phase_output(output_root, "malformed-formal", "calibrate"))

        @test nprocs() == 1
        run_phase(config_path, "calibrate", TEST_RUN_ID)
        @test nprocs() == 1
        @test isdir(calibration_output)
        @test !ispath(joinpath(output_root, TEST_TAG, TEST_RUN_ID, "calibration"))
        calibration_status = assert_strict_complete(
            calibration_output,
            "calibrate",
            Set(["value_functions/1.jld2"]),
        )
        value_function_path =
            joinpath(calibration_output, "value_functions", "1.jld2")
        value_function_payload = JLD2.load(value_function_path)
        @test size(value_function_payload["value_function"]) == (673, 11, 20)
        @test length(value_function_payload["alpha"]) == 672
        @test length(value_function_payload["beta"]) == 672
        @test all(isfinite, value_function_payload["alpha"])
        @test all(isfinite, value_function_payload["beta"])
        @test TOML.parsefile(joinpath(calibration_output, "provenance.toml"))["phase"] ==
              "calibrate"

        calibration_before_rerun = content_snapshot(recursive_files(calibration_output))
        run_phase(
            config_path,
            "calibrate",
            TEST_RUN_ID;
            resume=true,
            expect_success=false,
            expected_error="expected incomplete status, found complete",
        )
        @test content_snapshot(recursive_files(calibration_output)) ==
              calibration_before_rerun
        @test calibration_status ==
              RunContract.assert_complete!(calibration_output; phase="calibrate")

        calibration_manifest = joinpath(calibration_output, "artifacts.tsv")
        calibration_source_before =
            content_snapshot([value_function_path, calibration_manifest])

        bad_source_root = joinpath(temp, "bad-vf-run")
        bad_source = joinpath(bad_source_root, "value_functions")
        mkpath(bad_source)
        bad_value_function = joinpath(bad_source, "1.jld2")
        JLD2.save(bad_value_function, Dict("not_value_function" => 1))
        bad_manifest = joinpath(bad_source_root, "artifacts.tsv")
        Provenance.write_file_manifest(
            bad_manifest,
            [bad_value_function],
            bad_source_root,
        )
        run_phase(
            config_path,
            "simulate",
            "failed-source";
            vf_source=bad_source,
            vf_manifest=bad_manifest,
            expect_success=false,
            expected_error="value-function source is not an accepted recalibrated or audited legacy source",
        )
        failed_simulation = phase_output(output_root, "failed-source", "simulate")
        @test TOML.parsefile(joinpath(failed_simulation, "status.toml"))["state"] ==
              "incomplete"
        @test nprocs() == 1
        run_phase(
            config_path,
            "evaluate",
            "failed-source";
            simulation_source=failed_simulation,
            expect_success=false,
            expected_error="expected complete status, found incomplete",
        )
        failed_evaluation = phase_output(output_root, "failed-source", "evaluate")
        @test TOML.parsefile(joinpath(failed_evaluation, "status.toml"))["state"] ==
              "incomplete"
        @test !ispath(joinpath(failed_evaluation, "metrics.csv"))
        @test nprocs() == 1

        run_phase(
            config_path,
            "simulate",
            TEST_RUN_ID;
            vf_source=joinpath(calibration_output, "value_functions"),
            vf_manifest=calibration_manifest,
            run_output=simulation_output,
        )
        @test nprocs() == 1
        @test content_snapshot([value_function_path, calibration_manifest]) ==
              calibration_source_before
        assert_strict_complete(
            simulation_output,
            "simulate",
            Set(["1.jld2", "score.jld2"]),
        )
        simulation_path = joinpath(simulation_output, "1.jld2")
        score_path = joinpath(simulation_output, "score.jld2")
        simulations = JLD2.load(simulation_path, "simulations")
        @test length(simulations) == 1
        @test only(simulations).id.site_id == "1"
        @test only(simulations).id.period_id == "1"
        @test length(only(simulations).result.cost) == 1
        @test length(only(simulations).result.soc) == 1
        @test length(only(simulations).result.control) == 1
        @test length(only(simulations).timer) == 1
        @test Set(keys(JLD2.load(score_path))) == Set(["1"])
        simulation_provenance =
            TOML.parsefile(joinpath(simulation_output, "provenance.toml"))
        @test simulation_provenance["phase"] == "simulate"
        @test simulation_provenance["parameters"]["value_function_source_identity"]["type"] ==
              "recalibrated"
        @test TOML.parsefile(joinpath(simulation_output, "status.toml"))["fingerprint"] ==
              RunContract.fingerprint(simulation_provenance["parameters"])

        simulation_before_evaluation =
            content_snapshot(recursive_files(simulation_output))
        run_phase(
            config_path,
            "evaluate",
            TEST_RUN_ID;
            simulation_source=simulation_output,
        )
        @test nprocs() == 1
        @test content_snapshot(recursive_files(simulation_output)) ==
              simulation_before_evaluation
        assert_strict_complete(
            evaluation_output,
            "evaluate",
            Set(["metrics.csv"]),
        )
        metrics = CSV.read(
            joinpath(evaluation_output, "metrics.csv"),
            DataFrame;
            stringtype=String,
            types=Dict(:site => String),
        )
        @test names(metrics) == ["site", "cost", "gain", "score"]
        @test metrics.site == ["1"]
        @test all(isfinite, metrics.cost)
        @test all(isfinite, metrics.gain)
        @test all(isfinite, metrics.score)
        provenance = TOML.parsefile(joinpath(evaluation_output, "provenance.toml"))
        @test provenance["phase"] == "evaluate"
        @test provenance["tag"] == TEST_TAG
        @test provenance["run_id"] == TEST_RUN_ID
        @test provenance["parameters"]["experiment_config"] == config
        @test provenance["parameters"]["simulation_source_identity"]["type"] ==
              "strict_complete_simulation"
        @test TOML.parsefile(joinpath(evaluation_output, "status.toml"))["fingerprint"] ==
              RunContract.fingerprint(provenance["parameters"])

        @testset "derived output compatibility and completed reruns" begin
            mismatched_output = joinpath(temp, "caller-selected-output")
            run_phase(
                config_path,
                "calibrate",
                "output-mismatch";
                run_output=mismatched_output,
                expect_success=false,
                expected_error="RUN_OUTPUT_DIR must equal the derived phase output",
            )
            @test !ispath(mismatched_output)
            @test !ispath(phase_output(output_root, "output-mismatch", "calibrate"))

            run_phase(
                config_path,
                "simulate",
                TEST_RUN_ID;
                vf_source=joinpath(calibration_output, "value_functions"),
                vf_manifest=calibration_manifest,
                run_output=simulation_output,
                resume=true,
                expect_success=false,
                expected_error="expected incomplete status, found complete",
            )
            run_phase(
                config_path,
                "evaluate",
                TEST_RUN_ID;
                simulation_source=simulation_output,
                run_output=evaluation_output,
                resume=true,
                expect_success=false,
                expected_error="expected incomplete status, found complete",
            )
        end

        @testset "recalibrated source is strict complete and hash bound" begin
            source_copies = joinpath(temp, "calibration-source-copies")
            mkpath(source_copies)

            missing_run = copy_run_source(
                calibration_output,
                joinpath(source_copies, "missing", "calibrate"),
            )
            rm(joinpath(missing_run, "value_functions", "1.jld2"))
            run_phase(
                config_path,
                "simulate",
                "missing-vf";
                vf_source=joinpath(missing_run, "value_functions"),
                vf_manifest=joinpath(missing_run, "artifacts.tsv"),
                expect_success=false,
                expected_error="artifact manifest entry is missing",
            )

            payload_run = copy_run_source(
                calibration_output,
                joinpath(source_copies, "payload", "calibrate"),
            )
            open(joinpath(payload_run, "value_functions", "1.jld2"), "a") do io
                write(io, UInt8(0))
            end
            run_phase(
                config_path,
                "simulate",
                "vf-payload-mismatch";
                vf_source=joinpath(payload_run, "value_functions"),
                vf_manifest=joinpath(payload_run, "artifacts.tsv"),
                expect_success=false,
                expected_error="artifact hash mismatch: value_functions/1.jld2",
            )
            payload_failure = phase_output(output_root, "vf-payload-mismatch", "simulate")
            @test TOML.parsefile(joinpath(payload_failure, "status.toml"))["state"] ==
                  "incomplete"

            manifest_run = copy_run_source(
                calibration_output,
                joinpath(source_copies, "manifest", "calibrate"),
            )
            open(joinpath(manifest_run, "artifacts.tsv"), "a") do io
                write(io, "tampered\n")
            end
            run_phase(
                config_path,
                "simulate",
                "vf-manifest-mismatch";
                vf_source=joinpath(manifest_run, "value_functions"),
                vf_manifest=joinpath(manifest_run, "artifacts.tsv"),
                expect_success=false,
                expected_error="artifact manifest hash mismatch",
            )

            fail_trigger = joinpath(temp, "fail-calibration-before-work")
            write(fail_trigger, "fail\n")
            incomplete_config_path = joinpath(temp, "incomplete-calibration.toml")
            write_test_config(
                incomplete_config_path,
                fixture,
                output_root;
                development_settings=Dict{String,Any}(
                    "fail_before_work_file" => fail_trigger,
                ),
            )
            run_phase(
                incomplete_config_path,
                "calibrate",
                "incomplete-calibration";
                expect_success=false,
                expected_error="development fail-before-work hook",
            )
            incomplete_calibration =
                phase_output(output_root, "incomplete-calibration", "calibrate")
            @test TOML.parsefile(joinpath(incomplete_calibration, "status.toml"))["state"] ==
                  "incomplete"
            run_phase(
                config_path,
                "simulate",
                "reject-incomplete-calibration";
                vf_source=joinpath(incomplete_calibration, "value_functions"),
                vf_manifest=joinpath(incomplete_calibration, "artifacts.tsv"),
                expect_success=false,
                expected_error="expected complete status, found incomplete",
            )
        end

        @testset "audited legacy value functions use the Task4 contract" begin
            legacy_source =
                joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20", "value_functions")
            legacy_manifest =
                joinpath(ROOT, "baselines", "wdwe2_k20", "vf-manifest.tsv")
            run_phase(
                config_path,
                "simulate",
                "audited-legacy";
                vf_source=legacy_source,
                vf_manifest=legacy_manifest,
            )
            legacy_output = phase_output(output_root, "audited-legacy", "simulate")
            assert_strict_complete(
                legacy_output,
                "simulate",
                Set(["1.jld2", "score.jld2"]),
            )
            legacy_provenance =
                TOML.parsefile(joinpath(legacy_output, "provenance.toml"))
            identity = legacy_provenance["parameters"]["value_function_source_identity"]
            @test identity["type"] == "audited_legacy"
            @test identity["source"] == legacy_source
            @test identity["manifest_sha256"] == sha256_file(legacy_manifest)
            @test identity["value_function_count"] == 70
        end

        @testset "missing provenance resume is fail closed" begin
            fail_before_provenance = joinpath(temp, "fail-before-provenance")
            write(fail_before_provenance, "fail\n")
            resume_config_path = joinpath(temp, "resume-evaluation.toml")
            write_test_config(
                resume_config_path,
                fixture,
                output_root;
                development_settings=Dict{String,Any}(
                    "fail_before_provenance_file" => fail_before_provenance,
                ),
            )
            run_phase(
                resume_config_path,
                "evaluate",
                "resume-no-provenance";
                simulation_source=simulation_output,
                expect_success=false,
                expected_error="development fail-before-provenance hook",
            )
            resume_output =
                phase_output(output_root, "resume-no-provenance", "evaluate")
            @test Set(readdir(resume_output)) == Set(["status.toml"])
            rm(fail_before_provenance)
            run_phase(
                resume_config_path,
                "evaluate",
                "resume-no-provenance";
                simulation_source=simulation_output,
                resume=true,
            )
            assert_strict_complete(
                resume_output,
                "evaluate",
                Set(["metrics.csv"]),
            )

            fail_with_residue = joinpath(temp, "fail-with-residue")
            write(fail_with_residue, "fail\n")
            residue_config_path = joinpath(temp, "residue-evaluation.toml")
            write_test_config(
                residue_config_path,
                fixture,
                output_root;
                development_settings=Dict{String,Any}(
                    "fail_before_provenance_file" => fail_with_residue,
                ),
            )
            run_phase(
                residue_config_path,
                "evaluate",
                "resume-residue";
                simulation_source=simulation_output,
                expect_success=false,
                expected_error="development fail-before-provenance hook",
            )
            residue_output = phase_output(output_root, "resume-residue", "evaluate")
            write(joinpath(residue_output, "unexpected.bin"), "residue")
            rm(fail_with_residue)
            run_phase(
                residue_config_path,
                "evaluate",
                "resume-residue";
                simulation_source=simulation_output,
                resume=true,
                expect_success=false,
                expected_error="cannot recreate missing provenance after artifacts exist",
            )
        end

        @testset "simulation resume rejects malformed existing per-site artifacts" begin
            fail_before_score = joinpath(temp, "fail-before-score")
            resume_sim_config_path = joinpath(temp, "resume-simulation.toml")
            write_test_config(
                resume_sim_config_path,
                fixture,
                output_root;
                development_settings=Dict{String,Any}(
                    "fail_before_score_file" => fail_before_score,
                ),
            )
            calibration_all_before =
                content_snapshot(recursive_files(calibration_output))

            for (run_id, mutation) in (
                ("resume-truncated", :truncated),
                ("resume-missing-period", :missing_period),
            )
                write(fail_before_score, "fail\n")
                run_phase(
                    resume_sim_config_path,
                    "simulate",
                    run_id;
                    vf_source=joinpath(calibration_output, "value_functions"),
                    vf_manifest=calibration_manifest,
                    expect_success=false,
                    expected_error="development fail-before-score hook",
                )
                output = phase_output(output_root, run_id, "simulate")
                site_output = joinpath(output, "1.jld2")
                @test isfile(site_output)
                rm(fail_before_score)
                if mutation == :truncated
                    write(site_output, "truncated")
                else
                    JLD2.save(
                        site_output,
                        Dict("simulations" => EMSx.Simulation[]),
                    )
                end
                run_phase(
                    resume_sim_config_path,
                    "simulate",
                    run_id;
                    vf_source=joinpath(calibration_output, "value_functions"),
                    vf_manifest=calibration_manifest,
                    resume=true,
                    expect_success=false,
                    expected_error="invalid existing simulation artifact",
                )
                @test TOML.parsefile(joinpath(output, "status.toml"))["state"] ==
                      "incomplete"
            end
            @test content_snapshot(recursive_files(calibration_output)) ==
                  calibration_all_before
        end

        @testset "evaluation captures a sealed simulation identity" begin
            tamper_root = joinpath(temp, "simulation-source-copies")
            mkpath(tamper_root)
            expected_errors = Dict(
                :status => "simulation source status/provenance fingerprint mismatch",
                :provenance => "provenance hash mismatch",
                :score => "artifact hash mismatch",
                :per_site => "artifact hash mismatch",
            )
            for mutation in (:status, :provenance, :score, :per_site)
                source = copy_run_source(
                    simulation_output,
                    joinpath(tamper_root, string(mutation), "simulate"),
                )
                if mutation == :status
                    status_path = joinpath(source, "status.toml")
                    status = TOML.parsefile(status_path)
                    status["fingerprint"] = repeat("0", 64)
                    open(status_path, "w") do io
                        TOML.print(io, status; sorted=true)
                    end
                elseif mutation == :provenance
                    open(joinpath(source, "provenance.toml"), "a") do io
                        write(io, "tampered = true\n")
                    end
                elseif mutation == :score
                    open(joinpath(source, "score.jld2"), "a") do io
                        write(io, UInt8(0))
                    end
                else
                    open(joinpath(source, "1.jld2"), "a") do io
                        write(io, UInt8(0))
                    end
                end
                run_id = "tampered-$(mutation)"
                run_phase(
                    config_path,
                    "evaluate",
                    run_id;
                    simulation_source=source,
                    expect_success=false,
                    expected_error=expected_errors[mutation],
                )
                output = phase_output(output_root, run_id, "evaluate")
                @test TOML.parsefile(joinpath(output, "status.toml"))["state"] ==
                      "incomplete"
            end

            alias_source = joinpath(temp, "simulation-source-alias")
            symlink(simulation_output, alias_source)
            run_phase(
                config_path,
                "evaluate",
                "source-alias";
                simulation_source=alias_source,
                expect_success=false,
                expected_error="simulation source must not be a symlink",
            )
        end

        @testset "post-cleanup source checks and run lease are deterministic" begin
            pause_file = joinpath(temp, "pause-after-cleanup")
            pause_config_path = joinpath(temp, "pause-evaluation.toml")
            write_test_config(
                pause_config_path,
                fixture,
                output_root;
                development_settings=Dict{String,Any}(
                    "pause_after_cleanup_file" => pause_file,
                ),
            )

            concurrent_run = "concurrent-lease"
            concurrent_output = phase_output(output_root, concurrent_run, "evaluate")
            first = start_phase(
                pause_config_path,
                "evaluate",
                concurrent_run;
                simulation_source=simulation_output,
            )
            try
                wait_until(
                    () -> isfile(joinpath(concurrent_output, "metrics.csv")),
                    "paused evaluation metrics",
                )
                run_phase(
                    pause_config_path,
                    "evaluate",
                    concurrent_run;
                    simulation_source=simulation_output,
                    expect_success=false,
                    expected_error="run lease operation failed",
                )
                write(pause_file, "release\n")
                finish_phase(first; expect_success=true)
            finally
                isfile(pause_file) || write(pause_file, "release\n")
                process_running(first.process) && kill(first.process)
            end
            assert_strict_complete(
                concurrent_output,
                "evaluate",
                Set(["metrics.csv"]),
            )

            rm(pause_file)
            toctou_source = copy_run_source(
                simulation_output,
                joinpath(temp, "toctou-source", "simulate"),
            )
            toctou_run = "post-cleanup-toctou"
            toctou_output = phase_output(output_root, toctou_run, "evaluate")
            child = start_phase(
                pause_config_path,
                "evaluate",
                toctou_run;
                simulation_source=toctou_source,
            )
            try
                wait_until(
                    () -> isfile(joinpath(toctou_output, "metrics.csv")),
                    "post-cleanup evaluation pause",
                )
                open(joinpath(toctou_source, "score.jld2"), "a") do io
                    write(io, UInt8(0))
                end
                write(pause_file, "release\n")
                finish_phase(
                    child;
                    expect_success=false,
                    expected_error="simulation source changed after worker cleanup",
                )
            finally
                isfile(pause_file) || write(pause_file, "release\n")
                process_running(child.process) && kill(child.process)
            end
            @test TOML.parsefile(joinpath(toctou_output, "status.toml"))["state"] ==
                  "incomplete"
        end

        @test content_snapshot(recursive_files(simulation_output)) ==
              simulation_before_evaluation

        for phase_path in (calibration_output, simulation_output, evaluation_output)
            @test all(
                path -> !startswith(basename(path), ".tmp") &&
                        !occursin("staging", basename(path)),
                recursive_files(phase_path),
            )
        end

        Provenance.verify_manifest_snapshot(input_snapshot)
        Provenance.verify_stable_file_guard(config_guard)
        @test content_snapshot([
            fixture.prices,
            fixture.metadata,
            fixture.train_file,
            fixture.test_file,
            fixture.input_manifest,
        ]) == fixture_before
    end

    @test recursive_files(LEGACY_DIR) == legacy_paths
    @test content_snapshot(protected_paths) == protected_before
    @test formal_input_stat_snapshot() == formal_inputs_before
end

run_static_contract_tests()
