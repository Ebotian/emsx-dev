module WDWE2Reproduction

using CSV
using DataFrames
using SHA
using Statistics
using TOML

include(joinpath(@__DIR__, "..", "src", "RunContract.jl"))
using .RunContract

export compare_scores, finalize_reproduction

const ROOT = normpath(joinpath(@__DIR__, ".."))
const EXPECTED_SITE_IDS = collect(1:70)
const EXPECTED_MEAN_SCORE = 0.7676755785921663
const DEFAULT_REUSE_RUN_ID = "reuse-existing-vf-v1"
const DEFAULT_RECALIBRATED_RUN_ID = "recalibrated-v1"
const LEGACY_VF_HEADER =
    "site\tpath\tbytes\tsha256\thorizon\tsoc_points\tz_points\talpha_length\tbeta_length\tz_min\tz_max"
const LOWER_SHA256 = r"^[0-9a-f]{64}$"
const CANONICAL_INTEGER = r"^(0|[1-9][0-9]*)$"

sha256_file(path::String) = bytes2hex(open(SHA.sha256, path))

function _ordered_scores(frame::DataFrame, label::String)
    all(name -> name in names(frame), ["site", "score"]) ||
        error("$(label) scores must contain site and score columns")
    nrow(frame) == 70 || error("$(label) scores must contain exactly 70 rows")

    ids = try
        parse.(Int, string.(frame.site))
    catch err
        error("$(label) scores contain a non-integer site: $(sprint(showerror, err))")
    end
    length(unique(ids)) == length(ids) || error("$(label) scores contain duplicate sites")
    Set(ids) == Set(EXPECTED_SITE_IDS) || error("$(label) score sites must be exactly 1:70")

    scores = try
        Float64.(frame.score)
    catch err
        error("$(label) scores are not numeric: $(sprint(showerror, err))")
    end
    all(isfinite, scores) || error("$(label) scores contain non-finite values")
    order = sortperm(ids)
    return DataFrame(site=ids[order], score=scores[order])
end

function compare_scores(
    actual::DataFrame,
    expected::DataFrame;
    expected_mean::Float64=EXPECTED_MEAN_SCORE,
    mean_atol::Float64=1.0e-6,
    site_atol::Float64=1.0e-6,
)
    isfinite(mean_atol) && mean_atol >= 0 ||
        error("mean tolerance must be finite and non-negative")
    isfinite(site_atol) && site_atol >= 0 ||
        error("site tolerance must be finite and non-negative")
    isfinite(expected_mean) || error("expected mean score must be finite")

    actual = _ordered_scores(actual, "actual")
    expected = _ordered_scores(expected, "expected")
    mean_passed = isapprox(
        mean(actual.score),
        expected_mean;
        atol=mean_atol,
        rtol=0,
    )
    site_error = abs.(actual.score .- expected.score)
    all_sites_passed = all(site_error .<= site_atol)
    return (
        passed=mean_passed && all_sites_passed,
        mean_passed=mean_passed,
        all_sites_passed=all_sites_passed,
        mean_score=mean(actual.score),
        site_error=site_error,
        actual=actual,
        expected=expected,
    )
end

function _absolute_from_root(path::AbstractString, root::String)
    return normpath(isabspath(path) ? String(path) : joinpath(root, path))
end

function _assert_same_git!(left::AbstractDict, right::AbstractDict, label::String)
    left["outer_git_sha"] == right["outer_git_sha"] ||
        error("outer Git SHA mismatch across $(label)")
    left["nested_git_sha"] == right["nested_git_sha"] ||
        error("nested Git SHA mismatch across $(label)")
    return nothing
end

function _read_metrics(path::String, label::String)
    isfile(path) || error("missing $(label) metrics: $(path)")
    metrics = CSV.read(
        path,
        DataFrame;
        stringtype=String,
        types=Dict(:site => String),
    )
    names(metrics) == ["site", "cost", "gain", "score"] ||
        error("$(label) metrics have an invalid schema")
    all(name -> all(isfinite, Float64.(metrics[!, name])), ["cost", "gain", "score"]) ||
        error("$(label) metrics contain non-finite values")
    return metrics
end

function _read_provenance(
    run::String,
    phase::String,
    tag::String,
    run_id::String,
)
    status = RunContract.assert_complete!(run; phase=phase)
    provenance_path = joinpath(run, "provenance.toml")
    provenance = TOML.parsefile(provenance_path)
    provenance["phase"] == phase || error("$(phase) provenance phase mismatch")
    provenance["tag"] == tag || error("$(phase) provenance tag mismatch")
    provenance["run_id"] == run_id || error("$(phase) provenance run ID mismatch")
    parameters = get(provenance, "parameters", nothing)
    parameters isa AbstractDict || error("$(phase) provenance parameters are missing")
    canonical_parameters =
        Dict{String,Any}(String(key) => value for (key, value) in parameters)
    RunContract.fingerprint(canonical_parameters) == status["fingerprint"] ||
        error("$(phase) status/provenance fingerprint mismatch")
    return (
        status=status,
        provenance=provenance,
        parameters=canonical_parameters,
        provenance_path=provenance_path,
        manifest_path=joinpath(run, status["artifact_manifest"]),
    )
end

function _verify_formal_provenance!(
    sealed,
    root::String,
    config::Dict{String,Any};
    vf_manifest::Union{Nothing,String}=nothing,
)
    record = sealed.provenance
    expected_keys = Set((
        "schema_version", "captured_at_utc", "phase", "tag", "run_id",
        "julia_version", "cpu_name", "cpu_threads", "julia_threads",
        "blas_threads", "blas_config", "active_project", "emsx_path",
        "load_path", "outer_git_sha", "outer_git_dirty", "nested_git_sha",
        "nested_git_dirty", "project_sha256", "manifest_sha256",
        "input_manifest", "input_manifest_sha256", "vf_manifest",
        "vf_manifest_sha256", "parameters", "workers",
    ))
    Set(keys(record)) == expected_keys || error("formal provenance fields mismatch")
    record["schema_version"] === 1 || error("invalid provenance schema version")
    phase = String(record["phase"])
    parameter_keys = Set((
        "phase", "tag", "run_id", "parameters", "experiment_config",
        "value_function_source_dir", "value_function_manifest",
        "simulation_source_dir",
    ))
    phase == "simulate" && push!(parameter_keys, "value_function_source_identity")
    phase == "evaluate" && push!(parameter_keys, "simulation_source_identity")
    Set(keys(sealed.parameters)) == parameter_keys ||
        error("provenance run-config fields mismatch for $(phase)")
    sealed.parameters["phase"] == phase || error("provenance run-config phase mismatch")
    sealed.parameters["tag"] == record["tag"] || error("provenance run-config tag mismatch")
    sealed.parameters["run_id"] == record["run_id"] ||
        error("provenance run-config run ID mismatch")
    sealed.parameters["parameters"] == config["parameters"] ||
        error("provenance scientific parameters mismatch")
    sealed.parameters["experiment_config"] == config ||
        error("provenance experiment config mismatch")
    if phase == "calibrate"
        isempty(sealed.parameters["value_function_source_dir"]) &&
            isempty(sealed.parameters["value_function_manifest"]) &&
            isempty(sealed.parameters["simulation_source_dir"]) ||
            error("calibration run-config contains a source path")
    elseif phase == "simulate"
        !isempty(sealed.parameters["value_function_source_dir"]) &&
            !isempty(sealed.parameters["value_function_manifest"]) &&
            isempty(sealed.parameters["simulation_source_dir"]) ||
            error("simulation run-config source fields mismatch")
    else
        isempty(sealed.parameters["value_function_source_dir"]) &&
            isempty(sealed.parameters["value_function_manifest"]) &&
            !isempty(sealed.parameters["simulation_source_dir"]) ||
            error("evaluation run-config source fields mismatch")
    end
    record["outer_git_dirty"] === false || error("formal provenance records dirty outer source")
    record["nested_git_dirty"] === false || error("formal provenance records dirty nested source")
    occursin(r"^[0-9a-f]{40}$", record["outer_git_sha"]) ||
        error("invalid outer Git SHA in provenance")
    occursin(r"^[0-9a-f]{40}$", record["nested_git_sha"]) ||
        error("invalid nested Git SHA in provenance")

    project = joinpath(root, "Project.toml")
    manifest = joinpath(root, "Manifest.toml")
    emsx = joinpath(root, "EMSx.jl", "src", "EMSx.jl")
    record["active_project"] == project || error("provenance active project is not local")
    record["emsx_path"] == emsx || error("provenance EMSx path is not local")
    record["project_sha256"] == sha256_file(project) ||
        error("provenance Project.toml hash mismatch")
    record["manifest_sha256"] == sha256_file(manifest) ||
        error("provenance Manifest.toml hash mismatch")

    input_manifest = _absolute_from_root(
        String(config["inputs"]["input_manifest"]),
        root,
    )
    record["input_manifest"] == replace(relpath(input_manifest, root), '\\' => '/') ||
        error("provenance input manifest path mismatch")
    record["input_manifest_sha256"] == sha256_file(input_manifest) ||
        error("provenance input manifest hash mismatch")
    expected_vf_path = vf_manifest === nothing ? "" : replace(relpath(vf_manifest, root), '\\' => '/')
    expected_vf_hash = vf_manifest === nothing ? "" : sha256_file(vf_manifest)
    record["vf_manifest"] == expected_vf_path ||
        error("provenance VF manifest path mismatch")
    record["vf_manifest_sha256"] == expected_vf_hash ||
        error("provenance VF manifest hash mismatch")

    workers = record["workers"]
    workers isa AbstractVector || error("provenance workers must be an array")
    length(workers) == Int(config["execution"]["workers"]) ||
        error("provenance worker count mismatch")
    worker_ids = get.(workers, "worker", nothing)
    all(id -> id isa Integer && !(id isa Bool) && id > 1, worker_ids) ||
        error("provenance worker IDs are invalid")
    length(unique(worker_ids)) == length(worker_ids) ||
        error("provenance worker IDs are duplicated")
    for worker in workers
        Set(keys(worker)) == Set(("worker", "project", "emsx", "load_path")) ||
            error("provenance worker identity fields mismatch")
        worker["project"] == project || error("provenance worker project is not local")
        worker["emsx"] == emsx || error("provenance worker EMSx path is not local")
        worker["load_path"] == record["load_path"] ||
            error("provenance worker LOAD_PATH mismatch")
    end
    return nothing
end

function _artifact_manifest_paths(path::String)
    content = read(path, String)
    endswith(content, '\n') || error("artifact manifest must end with a newline")
    lines = split(content, '\n'; keepempty=true)
    isempty(last(lines)) || error("invalid artifact manifest line ending")
    pop!(lines)
    length(lines) >= 2 || error("artifact manifest contains no artifacts")
    first(lines) == "path\tbytes\tsha256" || error("invalid artifact manifest header")
    return [String(first(split(line, '\t'; keepempty=true))) for line in Iterators.drop(lines, 1)]
end

function _require_artifact_paths(path::String, expected::Set{String}, label::String)
    Set(_artifact_manifest_paths(path)) == expected ||
        error("$(label) artifact manifest has an unexpected path set")
    return nothing
end

function _verify_legacy_manifest!(root::String, source::String, manifest::String)
    isfile(manifest) || error("missing audited legacy VF manifest: $(manifest)")
    content = read(manifest, String)
    endswith(content, '\n') || error("legacy VF manifest must end with a newline")
    lines = split(content, '\n'; keepempty=true)
    isempty(last(lines)) || error("invalid legacy VF manifest line ending")
    pop!(lines)
    length(lines) == 71 || error("legacy VF manifest must contain 70 rows")
    first(lines) == LEGACY_VF_HEADER || error("invalid legacy VF manifest header")

    for (site, line) in enumerate(Iterators.drop(lines, 1))
        fields = split(line, '\t'; keepempty=true)
        length(fields) == 11 || error("invalid legacy VF manifest row")
        site_text, relative, bytes_text, digest, horizon, soc_points, z_points,
            alpha_length, beta_length, z_min_text, z_max_text = fields
        site_text == string(site) || error("legacy VF manifest sites must be exactly 1:70")
        relative == "results_sdp/sweep_wdwe2_k20/value_functions/$(site).jld2" ||
            error("legacy VF manifest path mismatch for site $(site)")
        all(
            text -> occursin(CANONICAL_INTEGER, text),
            (bytes_text, horizon, soc_points, z_points, alpha_length, beta_length),
        ) || error("invalid legacy VF integer metadata for site $(site)")
        occursin(LOWER_SHA256, digest) || error("invalid legacy VF hash for site $(site)")
        parse(Int, horizon) == 673 || error("invalid legacy VF horizon for site $(site)")
        parse(Int, soc_points) == 11 || error("invalid legacy VF SoC grid for site $(site)")
        parse(Int, z_points) == 20 || error("invalid legacy VF z grid for site $(site)")
        parse(Int, alpha_length) == 672 ||
            error("invalid legacy VF alpha length for site $(site)")
        parse(Int, beta_length) == 672 ||
            error("invalid legacy VF beta length for site $(site)")
        z_min = tryparse(Float64, z_min_text)
        z_max = tryparse(Float64, z_max_text)
        z_min !== nothing && z_max !== nothing && isfinite(z_min) && isfinite(z_max) &&
            z_min < z_max || error("invalid legacy VF bounds for site $(site)")

        path = joinpath(root, split(relative, '/')...)
        path == joinpath(source, "$(site).jld2") ||
            error("legacy VF source does not match its manifest")
        isfile(path) || error("missing legacy VF for site $(site)")
        islink(path) && error("legacy VF must not be a symlink for site $(site)")
        filesize(path) == parse(Int, bytes_text) ||
            error("legacy VF byte count mismatch for site $(site)")
        sha256_file(path) == digest || error("legacy VF hash mismatch for site $(site)")
    end
    return sha256_file(manifest)
end

function _verify_legacy_contract!(
    root::String,
    baseline_dir::String,
    source::String,
    manifest::String,
    scores_path::String,
)
    contract_path = joinpath(baseline_dir, "legacy-source.toml")
    isfile(contract_path) || error("missing audited legacy source contract")
    contract = TOML.parsefile(contract_path)
    expected_keys = Set((
        "schema_version", "input_manifest_path", "input_manifest_sha256",
        "legacy_environment_lock", "legacy_log_bytes", "legacy_log_path",
        "legacy_log_sha256", "legacy_score_bytes", "legacy_score_path",
        "legacy_score_sha256", "scores_path", "scores_sha256",
        "value_function_count", "value_function_directory", "vf_manifest_path",
        "vf_manifest_sha256",
    ))
    Set(keys(contract)) == expected_keys || error("invalid audited legacy source fields")
    contract["schema_version"] === 1 || error("invalid audited legacy schema version")
    contract["legacy_environment_lock"] == "not_recorded_by_legacy_run" ||
        error("invalid audited legacy environment lock")
    contract["value_function_count"] === 70 || error("invalid audited legacy VF count")

    expected_paths = Dict(
        "input_manifest_path" => joinpath(baseline_dir, "input-manifest.tsv"),
        "legacy_log_path" => joinpath(root, "results_sdp", "sweep_wdwe2_k20.log"),
        "legacy_score_path" =>
            joinpath(root, "results_sdp", "sweep_wdwe2_k20", "score.jld2"),
        "scores_path" => scores_path,
        "vf_manifest_path" => manifest,
    )
    hash_keys = Dict(
        "input_manifest_path" => "input_manifest_sha256",
        "legacy_log_path" => "legacy_log_sha256",
        "legacy_score_path" => "legacy_score_sha256",
        "scores_path" => "scores_sha256",
        "vf_manifest_path" => "vf_manifest_sha256",
    )
    byte_keys = Dict(
        "legacy_log_path" => "legacy_log_bytes",
        "legacy_score_path" => "legacy_score_bytes",
    )
    for (path_key, path) in expected_paths
        contract[path_key] == replace(relpath(path, root), '\\' => '/') ||
            error("audited legacy $(path_key) mismatch")
        isfile(path) || error("audited legacy referenced file is missing: $(path)")
        sha256_file(path) == contract[hash_keys[path_key]] ||
            error("audited legacy hash mismatch for $(path_key)")
        if haskey(byte_keys, path_key)
            filesize(path) == contract[byte_keys[path_key]] ||
                error("audited legacy byte count mismatch for $(path_key)")
        end
    end
    contract["value_function_directory"] == replace(relpath(source, root), '\\' => '/') ||
        error("audited legacy value-function directory mismatch")
    return (contract=contract, path=contract_path, sha256=sha256_file(contract_path))
end

function _validate_simulation_source!(
    root::String,
    config::Dict{String,Any},
    baseline_dir::String,
    baseline_scores_path::String,
    output_root::String,
    tag::String,
    run_id::String,
    expected_type::String,
)
    simulation = joinpath(output_root, tag, run_id, "simulate")
    sealed = _read_provenance(simulation, "simulate", tag, run_id)
    _require_artifact_paths(
        sealed.manifest_path,
        Set(vcat(["$(site).jld2" for site in 1:70], ["score.jld2"])),
        "simulation",
    )

    parameters = sealed.parameters
    identity = get(parameters, "value_function_source_identity", nothing)
    identity isa AbstractDict || error("simulation VF source identity is missing")
    get(identity, "type", nothing) == expected_type ||
        error("simulation VF source type must be $(expected_type)")
    source = _absolute_from_root(String(get(identity, "source", "")), root)
    parameter_source = _absolute_from_root(
        String(get(parameters, "value_function_source_dir", "")),
        root,
    )
    source == parameter_source || error("simulation VF source identity/path mismatch")
    manifest = _absolute_from_root(
        String(get(parameters, "value_function_manifest", "")),
        root,
    )
    _verify_formal_provenance!(sealed, root, config; vf_manifest=manifest)

    source_manifest_sha = if expected_type == "audited_legacy"
        Set(keys(identity)) == Set((
            "type", "source", "manifest_sha256", "legacy_contract_sha256",
            "value_function_count", "source_fingerprint",
        )) || error("audited legacy VF identity fields mismatch")
        expected_source = joinpath(
            root,
            "results_sdp",
            "sweep_wdwe2_k20",
            "value_functions",
        )
        expected_manifest = joinpath(baseline_dir, "vf-manifest.tsv")
        source == expected_source || error("audited legacy VF source path mismatch")
        manifest == expected_manifest || error("audited legacy VF manifest path mismatch")
        digest = _verify_legacy_manifest!(root, source, manifest)
        contract = _verify_legacy_contract!(
            root,
            baseline_dir,
            source,
            manifest,
            baseline_scores_path,
        )
        identity["manifest_sha256"] == digest ||
            error("audited legacy VF identity hash mismatch")
        identity["legacy_contract_sha256"] == contract.sha256 ||
            error("audited legacy contract identity hash mismatch")
        identity["source_fingerprint"] == digest ||
            error("audited legacy source fingerprint mismatch")
        identity["value_function_count"] === 70 ||
            error("audited legacy VF identity count mismatch")
        digest
    else
        Set(keys(identity)) == Set((
            "type", "source", "run", "source_fingerprint", "status_sha256",
            "provenance_sha256", "manifest_sha256", "value_function_count",
        )) || error("recalibrated VF identity fields mismatch")
        calibration = joinpath(output_root, tag, run_id, "calibrate")
        expected_source = joinpath(calibration, "value_functions")
        expected_manifest = joinpath(calibration, "artifacts.tsv")
        source == expected_source || error("recalibrated VF source must use calibration artifacts")
        manifest == expected_manifest ||
            error("recalibrated VF manifest must be calibration artifacts.tsv")
        _absolute_from_root(String(identity["run"]), root) == calibration ||
            error("recalibrated VF identity run mismatch")
        calibration_sealed = _read_provenance(calibration, "calibrate", tag, run_id)
        _verify_formal_provenance!(calibration_sealed, root, config)
        _assert_same_git!(sealed.provenance, calibration_sealed.provenance, "calibration and simulation")
        _require_artifact_paths(
            calibration_sealed.manifest_path,
            Set("value_functions/$(site).jld2" for site in 1:70),
            "calibration",
        )
        digest = sha256_file(calibration_sealed.manifest_path)
        identity["source_fingerprint"] == calibration_sealed.status["fingerprint"] ||
            error("recalibrated VF source fingerprint mismatch")
        identity["status_sha256"] == sha256_file(joinpath(calibration, "status.toml")) ||
            error("recalibrated VF status identity hash mismatch")
        identity["provenance_sha256"] ==
            sha256_file(calibration_sealed.provenance_path) ||
            error("recalibrated VF provenance identity hash mismatch")
        identity["manifest_sha256"] == digest ||
            error("recalibrated VF manifest identity hash mismatch")
        identity["value_function_count"] === 70 ||
            error("recalibrated VF identity count mismatch")
        digest
    end

    return (
        run=simulation,
        status=sealed.status,
        provenance=sealed.provenance,
        provenance_path=sealed.provenance_path,
        manifest_path=sealed.manifest_path,
        source_manifest_sha256=source_manifest_sha,
    )
end

function _validate_acceptance_path(
    root::String,
    config::Dict{String,Any},
    baseline_dir::String,
    baseline_scores_path::String,
    output_root::String,
    tag::String,
    run_id::String,
    expected_type::String,
    expected::DataFrame;
    expected_mean::Float64,
    mean_atol::Float64,
    site_atol::Float64,
)
    evaluation = joinpath(output_root, tag, run_id, "evaluate")
    sealed = _read_provenance(evaluation, "evaluate", tag, run_id)
    _verify_formal_provenance!(sealed, root, config)
    _require_artifact_paths(sealed.manifest_path, Set(["metrics.csv"]), "evaluation")

    expected_simulation = joinpath(output_root, tag, run_id, "simulate")
    parameters = sealed.parameters
    simulation_setting = _absolute_from_root(
        String(get(parameters, "simulation_source_dir", "")),
        root,
    )
    simulation_setting == expected_simulation ||
        error("evaluation must use its auto-derived simulation path")
    simulation_identity = get(parameters, "simulation_source_identity", nothing)
    simulation_identity isa AbstractDict || error("evaluation simulation identity is missing")
    Set(keys(simulation_identity)) == Set((
        "type", "source", "source_fingerprint", "status_sha256",
        "provenance_sha256", "manifest_sha256", "artifact_count",
    )) || error("evaluation simulation identity fields mismatch")
    simulation_identity["type"] == "strict_complete_simulation" ||
        error("evaluation simulation identity type mismatch")
    _absolute_from_root(String(simulation_identity["source"]), root) ==
        expected_simulation || error("evaluation simulation identity path mismatch")

    simulation = _validate_simulation_source!(
        root,
        config,
        baseline_dir,
        baseline_scores_path,
        output_root,
        tag,
        run_id,
        expected_type,
    )
    simulation_identity["source_fingerprint"] == simulation.status["fingerprint"] ||
        error("evaluation simulation fingerprint mismatch")
    simulation_identity["status_sha256"] ==
        sha256_file(joinpath(simulation.run, "status.toml")) ||
        error("evaluation simulation status identity hash mismatch")
    simulation_identity["provenance_sha256"] == sha256_file(simulation.provenance_path) ||
        error("evaluation simulation provenance identity hash mismatch")
    simulation_identity["manifest_sha256"] == sha256_file(simulation.manifest_path) ||
        error("evaluation simulation manifest identity hash mismatch")
    simulation_identity["artifact_count"] === 71 ||
        error("evaluation simulation artifact count mismatch")
    _assert_same_git!(sealed.provenance, simulation.provenance, "simulation and evaluation")

    metrics_path = joinpath(evaluation, "metrics.csv")
    metrics = _read_metrics(metrics_path, run_id)
    comparison = compare_scores(
        metrics,
        expected;
        expected_mean=expected_mean,
        mean_atol=mean_atol,
        site_atol=site_atol,
    )
    comparison.passed || error("$(run_id) failed the WDWE2 score regression")
    return (
        comparison=comparison,
        metrics=metrics,
        metrics_path=metrics_path,
        evaluation_manifest_path=sealed.manifest_path,
        evaluation_provenance_path=sealed.provenance_path,
        simulation_manifest_path=simulation.manifest_path,
        simulation_provenance_path=simulation.provenance_path,
        source_manifest_sha256=simulation.source_manifest_sha256,
        outer_git_sha=sealed.provenance["outer_git_sha"],
        nested_git_sha=sealed.provenance["nested_git_sha"],
    )
end

function _reproduced_scores(expected::DataFrame, reuse, recalibrated)
    legacy = _ordered_scores(expected, "expected")
    return DataFrame(
        site=legacy.site,
        legacy_score=legacy.score,
        reuse_score=reuse.comparison.actual.score,
        recalibrated_score=recalibrated.comparison.actual.score,
        reuse_absolute_error=reuse.comparison.site_error,
        recalibrated_absolute_error=recalibrated.comparison.site_error,
    )
end

function _toml_bytes(record::Dict{String,Any})
    io = IOBuffer()
    TOML.print(io, record; sorted=true)
    return take!(io)
end

function _csv_bytes(frame::DataFrame)
    return mktempdir() do temp
        path = joinpath(temp, "reproduced-scores.csv")
        CSV.write(path, frame)
        read(path)
    end
end

function _publish_evidence_immutably(outputs::Dict{String,Vector{UInt8}})
    length(outputs) == 2 || error("acceptance evidence must contain exactly two files")
    paths = sort!(collect(keys(outputs)))
    length(unique(paths)) == 2 || error("acceptance evidence output paths must be unique")
    parents = unique(dirname.(paths))
    length(parents) == 1 || error("acceptance evidence outputs must share a directory")
    parent = only(parents)
    isdir(parent) || error("acceptance evidence directory is missing: $(parent)")
    islink(parent) && error("acceptance evidence directory must not be a symlink")
    normpath(abspath(parent)) == realpath(parent) ||
        error("acceptance evidence directory must not traverse symlinks")
    for path in paths
        (ispath(path) || islink(path)) && error("refusing to overwrite acceptance evidence: $(path)")
    end

    staging = mktempdir(parent; prefix=".wdwe2-reproduction-staging-")
    installed = String[]
    staged = Dict{String,String}()
    try
        for path in paths
            temporary = joinpath(staging, basename(path))
            write(temporary, outputs[path])
            staged[path] = temporary
        end
        for path in paths
            temporary = staged[path]
            Base.Filesystem.hardlink(temporary, path)
            stat(temporary).inode == stat(path).inode ||
                error("acceptance evidence publication identity mismatch")
            push!(installed, path)
        end
    catch
        for path in reverse(installed)
            temporary = staged[path]
            if isfile(path) && stat(temporary).device == stat(path).device &&
               stat(temporary).inode == stat(path).inode
                rm(path)
            end
        end
        rethrow()
    finally
        ispath(staging) && rm(staging; recursive=true, force=true)
    end
    return nothing
end

function finalize_reproduction(;
    root::String=ROOT,
    config_path::String=joinpath(root, "configs", "wdwe2_k20.toml"),
    baseline_dir::String=joinpath(root, "baselines", "wdwe2_k20"),
    output_root::String=joinpath(root, "results_sdp", "runs"),
    reuse_run_id::String=DEFAULT_REUSE_RUN_ID,
    recalibrated_run_id::String=DEFAULT_RECALIBRATED_RUN_ID,
)
    root = normpath(abspath(root))
    config_path = normpath(abspath(config_path))
    baseline_dir = normpath(abspath(baseline_dir))
    output_root = normpath(abspath(output_root))
    try
        RunContract.validate_component(reuse_run_id, "reuse RUN_ID")
    catch err
        error("invalid reuse RUN_ID: $(sprint(showerror, err))")
    end
    try
        RunContract.validate_component(recalibrated_run_id, "recalibrated RUN_ID")
    catch err
        error("invalid recalibrated RUN_ID: $(sprint(showerror, err))")
    end
    reuse_run_id != recalibrated_run_id || error("acceptance run IDs must be distinct")
    report_path = joinpath(baseline_dir, "reproduction.toml")
    scores_path = joinpath(baseline_dir, "reproduced-scores.csv")
    for path in (report_path, scores_path)
        (ispath(path) || islink(path)) && error("refusing to overwrite acceptance evidence: $(path)")
    end

    config = TOML.parsefile(config_path)
    experiment = config["experiment"]
    acceptance = config["acceptance"]
    tag = String(experiment["tag"])
    RunContract.validate_component(tag, "TAG")
    expected_sites = Int(experiment["expected_sites"])
    expected_sites == 70 || error("finalizer requires exactly 70 configured sites")
    expected_mean = Float64(acceptance["expected_mean_score"])
    mean_atol = Float64(acceptance["mean_atol"])
    site_atol = Float64(acceptance["site_atol"])
    expected_mean == EXPECTED_MEAN_SCORE || error("unexpected WDWE2 reference mean")
    mean_atol == 1.0e-6 || error("WDWE2 mean tolerance must remain exactly 1e-6")
    site_atol == 1.0e-6 || error("WDWE2 site tolerance must remain exactly 1e-6")

    baseline_scores_path = joinpath(baseline_dir, "scores.csv")
    expected = _read_metrics(baseline_scores_path, "legacy baseline")
    baseline_scores_sha = sha256_file(baseline_scores_path)

    reuse = _validate_acceptance_path(
        root,
        config,
        baseline_dir,
        baseline_scores_path,
        output_root,
        tag,
        reuse_run_id,
        "audited_legacy",
        expected;
        expected_mean=expected_mean,
        mean_atol=mean_atol,
        site_atol=site_atol,
    )
    recalibrated = _validate_acceptance_path(
        root,
        config,
        baseline_dir,
        baseline_scores_path,
        output_root,
        tag,
        recalibrated_run_id,
        "recalibrated",
        expected;
        expected_mean=expected_mean,
        mean_atol=mean_atol,
        site_atol=site_atol,
    )
    sha256_file(baseline_scores_path) == baseline_scores_sha ||
        error("legacy baseline scores changed during finalization")
    reuse.outer_git_sha == recalibrated.outer_git_sha ||
        error("outer Git SHA mismatch across acceptance paths")
    reuse.nested_git_sha == recalibrated.nested_git_sha ||
        error("nested Git SHA mismatch across acceptance paths")

    report = Dict{String,Any}(
        "schema_version" => 1,
        "site_count" => 70,
        "outer_git_sha" => reuse.outer_git_sha,
        "nested_git_sha" => reuse.nested_git_sha,
        "expected_mean_score" => expected_mean,
        "mean_atol" => mean_atol,
        "site_atol" => site_atol,
        "baseline_scores_sha256" => baseline_scores_sha,
        "legacy_source_contract_sha256" =>
            sha256_file(joinpath(baseline_dir, "legacy-source.toml")),
        "legacy_vf_manifest_sha256" => reuse.source_manifest_sha256,
        "reuse_existing_vf_run_id" => reuse_run_id,
        "reuse_existing_vf_mean_score" => reuse.comparison.mean_score,
        "reuse_existing_vf_mean_passed" => reuse.comparison.mean_passed,
        "reuse_existing_vf_all_sites_passed" => reuse.comparison.all_sites_passed,
        "reuse_existing_vf_passed" => reuse.comparison.passed,
        "reuse_existing_vf_metrics_sha256" => sha256_file(reuse.metrics_path),
        "reuse_existing_vf_evaluation_manifest_sha256" =>
            sha256_file(reuse.evaluation_manifest_path),
        "reuse_existing_vf_evaluation_provenance_sha256" =>
            sha256_file(reuse.evaluation_provenance_path),
        "reuse_existing_vf_simulation_manifest_sha256" =>
            sha256_file(reuse.simulation_manifest_path),
        "reuse_existing_vf_simulation_provenance_sha256" =>
            sha256_file(reuse.simulation_provenance_path),
        "recalibrated_run_id" => recalibrated_run_id,
        "recalibrated_mean_score" => recalibrated.comparison.mean_score,
        "recalibrated_mean_passed" => recalibrated.comparison.mean_passed,
        "recalibrated_all_sites_passed" => recalibrated.comparison.all_sites_passed,
        "recalibrated_passed" => recalibrated.comparison.passed,
        "recalibrated_metrics_sha256" => sha256_file(recalibrated.metrics_path),
        "recalibrated_evaluation_manifest_sha256" =>
            sha256_file(recalibrated.evaluation_manifest_path),
        "recalibrated_evaluation_provenance_sha256" =>
            sha256_file(recalibrated.evaluation_provenance_path),
        "recalibrated_simulation_manifest_sha256" =>
            sha256_file(recalibrated.simulation_manifest_path),
        "recalibrated_simulation_provenance_sha256" =>
            sha256_file(recalibrated.simulation_provenance_path),
        "recalibrated_calibration_manifest_sha256" =>
            recalibrated.source_manifest_sha256,
    )
    reproduced = _reproduced_scores(expected, reuse, recalibrated)
    outputs = Dict(
        report_path => _toml_bytes(report),
        scores_path => _csv_bytes(reproduced),
    )
    _publish_evidence_immutably(outputs)

    parsed = TOML.parsefile(report_path)
    parsed == report || error("published reproduction report failed validation")
    published_scores = CSV.read(scores_path, DataFrame; stringtype=String)
    names(published_scores) == names(reproduced) ||
        error("published reproduced scores failed validation")
    return report_path, scores_path
end

function main()
    finalize_reproduction(
        reuse_run_id=get(ENV, "REUSE_RUN_ID", DEFAULT_REUSE_RUN_ID),
        recalibrated_run_id=get(
            ENV,
            "RECALIBRATED_RUN_ID",
            DEFAULT_RECALIBRATED_RUN_ID,
        ),
    )
    return nothing
end

end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    WDWE2Reproduction.main()
end
