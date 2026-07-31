module WDWE2BaselineCapture

using CSV
using DataFrames
using EMSx
using JLD2
using SHA
using Statistics
using StoOpt
using TOML

include(joinpath(@__DIR__, "..", "src", "Provenance.jl"))
using .Provenance

const ROOT = normpath(joinpath(@__DIR__, ".."))
const BASELINE_DIR = joinpath(ROOT, "baselines", "wdwe2_k20")
const LEGACY_RESULT_DIR = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20")
const LEGACY_SCORE = joinpath(LEGACY_RESULT_DIR, "score.jld2")
const LEGACY_LOG = joinpath(ROOT, "results_sdp", "sweep_wdwe2_k20.log")
const LEGACY_VF_DIR = joinpath(LEGACY_RESULT_DIR, "value_functions")
const EXPECTED_LEGACY_MEAN = 0.7676755785921663

bytes(text::String) = Vector{UInt8}(codeunits(text))
sha256_bytes(content::Vector{UInt8}) = bytes2hex(SHA.sha256(content))

function formal_input_files()
    files = String[]
    append!(files, [joinpath(ROOT, "dataset", "train", "$(site).csv.gz") for site in 1:70])
    append!(files, [joinpath(ROOT, "dataset", "test", "$(site).csv.gz") for site in 1:70])
    append!(
        files,
        [
            joinpath(ROOT, "dataset", "metadata.csv"),
            joinpath(ROOT, "EMSx.jl", "metadata", "edf_prices.csv"),
            joinpath(ROOT, "EMSx.jl", "metadata", "baseline", "dummy.jld2"),
            joinpath(
                ROOT,
                "EMSx.jl",
                "metadata",
                "baseline",
                "anticipative.jld2",
            ),
        ],
    )
    length(files) == 144 || error("expected 144 formal inputs, found $(length(files))")
    length(unique(files)) == 144 || error("formal input list contains duplicates")
    return files
end

function render_input_manifest()
    mktempdir() do temp
        output = joinpath(temp, "input-manifest.tsv")
        Provenance.write_file_manifest(output, formal_input_files(), ROOT)
        lines = readlines(output)
        length(lines) == 145 || error("expected 144 input rows")
        return read(output)
    end
end

function sort_sites_numerically!(metrics::DataFrame)
    order = sortperm(parse.(Int, string.(metrics.site)))
    permute!(metrics, order)
    return metrics
end

function render_scores()
    isfile(LEGACY_SCORE) || error("missing legacy score: $(LEGACY_SCORE)")
    metrics = EMSx.evaluate_model(LEGACY_SCORE)
    nrow(metrics) == 70 || error("expected 70 legacy score rows")
    sort_sites_numerically!(metrics)
    metrics.site == string.(1:70) || error("legacy score sites are not 1:70")
    isapprox(mean(metrics.score), EXPECTED_LEGACY_MEAN; atol=1e-12, rtol=0) ||
        error("unexpected legacy mean score: $(mean(metrics.score))")
    select!(metrics, [:site, :cost, :gain, :score])

    return mktempdir() do temp
        output = joinpath(temp, "scores.csv")
        CSV.write(output, metrics)
        read(output)
    end
end

function render_vf_manifest()
    io = IOBuffer()
    println(
        io,
        "site\tpath\tbytes\tsha256\thorizon\tsoc_points\tz_points\talpha_length\tbeta_length\tz_min\tz_max",
    )

    for site in 1:70
        path = joinpath(LEGACY_VF_DIR, "$(site).jld2")
        isfile(path) || error("missing legacy value function: $(path)")
        payload = JLD2.load(path)
        shape = size(payload["value_function"])
        alpha_length = length(payload["alpha"])
        beta_length = length(payload["beta"])
        shape == (673, 11, 20) ||
            error("unexpected value-function shape for site $(site): $(shape)")
        alpha_length == 672 ||
            error("unexpected alpha length for site $(site): $(alpha_length)")
        beta_length == 672 ||
            error("unexpected beta length for site $(site): $(beta_length)")

        println(
            io,
            join(
                (
                    site,
                    relpath(path, ROOT),
                    filesize(path),
                    Provenance.sha256_file(path),
                    shape[1],
                    shape[2],
                    shape[3],
                    alpha_length,
                    beta_length,
                    payload["z_min"],
                    payload["z_max"],
                ),
                '\t',
            ),
        )
    end

    return take!(io)
end

function render_legacy_source(
    input_manifest::Vector{UInt8},
    scores::Vector{UInt8},
    vf_manifest::Vector{UInt8},
)
    isfile(LEGACY_LOG) || error("missing legacy log: $(LEGACY_LOG)")
    record = Dict{String,Any}(
        "schema_version" => 1,
        "legacy_environment_lock" => "not_recorded_by_legacy_run",
        "legacy_score_path" => relpath(LEGACY_SCORE, ROOT),
        "legacy_score_bytes" => filesize(LEGACY_SCORE),
        "legacy_score_sha256" => Provenance.sha256_file(LEGACY_SCORE),
        "legacy_log_path" => relpath(LEGACY_LOG, ROOT),
        "legacy_log_bytes" => filesize(LEGACY_LOG),
        "legacy_log_sha256" => Provenance.sha256_file(LEGACY_LOG),
        "value_function_directory" => relpath(LEGACY_VF_DIR, ROOT),
        "value_function_count" => 70,
        "input_manifest_path" => relpath(
            joinpath(BASELINE_DIR, "input-manifest.tsv"),
            ROOT,
        ),
        "input_manifest_sha256" => sha256_bytes(input_manifest),
        "scores_path" => relpath(joinpath(BASELINE_DIR, "scores.csv"), ROOT),
        "scores_sha256" => sha256_bytes(scores),
        "vf_manifest_path" => relpath(
            joinpath(BASELINE_DIR, "vf-manifest.tsv"),
            ROOT,
        ),
        "vf_manifest_sha256" => sha256_bytes(vf_manifest),
    )
    io = IOBuffer()
    TOML.print(io, record; sorted=true)
    return take!(io)
end

function _validate_fixture_set(
    target::String,
    outputs::Dict{String,Vector{UInt8}},
)
    islink(target) && error("fixture set directory must not be a symlink: $(target)")
    isdir(target) || error("fixture set is not a directory: $(target)")
    expected_names = sort!(basename.(collect(keys(outputs))))
    readdir(target; sort=true) == expected_names ||
        error("fixture set is partial or contains unexpected files: $(target)")
    for path in sort!(collect(keys(outputs)))
        isfile(path) || error("fixture path is not a file: $(path)")
        islink(path) && error("fixture path must not be a symlink: $(path)")
        read(path) == outputs[path] ||
            error("refusing to overwrite different fixture: $(path)")
    end
    return nothing
end

function _publish_staged_directory(staging::String, target::String)
    Sys.islinux() ||
        error("atomic no-overwrite fixture-set publication requires Linux")
    result = ccall(
        :renameat2,
        Cint,
        (Cint, Cstring, Cint, Cstring, Cuint),
        -100,
        staging,
        -100,
        target,
        UInt32(1),
    )
    result == 0 || error(
        "atomic fixture publish failed for $(target): " *
        Base.Libc.strerror(Base.Libc.errno()),
    )
    return nothing
end

function write_outputs_immutably(
    outputs::Dict{String,Vector{UInt8}};
    _before_publish::Function=(staging, target) -> nothing,
)
    length(outputs) == 4 || error("fixture set must contain exactly four files")
    canonical_outputs = Dict{String,Vector{UInt8}}()
    for (path, content) in outputs
        canonical = normpath(abspath(path))
        haskey(canonical_outputs, canonical) &&
            error("fixture output paths are not unique")
        canonical_outputs[canonical] = content
    end
    ordered_paths = sort!(collect(keys(canonical_outputs)))
    target_directories = unique(dirname.(ordered_paths))
    length(target_directories) == 1 ||
        error("all fixture outputs must share one target directory")
    target = only(target_directories)
    length(unique(basename.(ordered_paths))) == 4 ||
        error("fixture output names are not unique")

    if ispath(target)
        _validate_fixture_set(target, canonical_outputs)
        return nothing
    end

    parent = dirname(target)
    isdir(parent) || error("fixture target parent must already exist: $(parent)")
    parent_absolute = normpath(abspath(parent))
    realpath(parent_absolute) == parent_absolute ||
        error("fixture target parent must not traverse symlinks: $(parent)")
    staging = mktempdir(parent; prefix=".wdwe2-fixture-staging-")
    try
        for path in ordered_paths
            staged_path = joinpath(staging, basename(path))
            open(staged_path, "w") do io
                write(io, canonical_outputs[path])
            end
        end
        staged_outputs = Dict(
            joinpath(staging, basename(path)) => canonical_outputs[path] for
            path in ordered_paths
        )
        _validate_fixture_set(staging, staged_outputs)
        _before_publish(staging, target)
        _validate_fixture_set(staging, staged_outputs)
        _publish_staged_directory(staging, target)
        _validate_fixture_set(target, canonical_outputs)
    finally
        ispath(staging) && rm(staging; recursive=true)
    end
    return nothing
end

function main()
    input_manifest = render_input_manifest()
    scores = render_scores()
    vf_manifest = render_vf_manifest()
    legacy_source = render_legacy_source(input_manifest, scores, vf_manifest)
    outputs = Dict(
        joinpath(BASELINE_DIR, "input-manifest.tsv") => input_manifest,
        joinpath(BASELINE_DIR, "scores.csv") => scores,
        joinpath(BASELINE_DIR, "vf-manifest.tsv") => vf_manifest,
        joinpath(BASELINE_DIR, "legacy-source.toml") => legacy_source,
    )
    write_outputs_immutably(outputs)
    return nothing
end

end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    WDWE2BaselineCapture.main()
end
