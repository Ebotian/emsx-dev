using CSV
using DataFrames
using JLD2
using Statistics
using StoOpt
using Test
using TOML

const BASELINE_ROOT = normpath(joinpath(@__DIR__, ".."))
const BASELINE_DIR = joinpath(BASELINE_ROOT, "baselines", "wdwe2_k20")
const BASELINE_CAPTURE_SCRIPT =
    joinpath(BASELINE_ROOT, "scripts", "capture_wdwe2_baseline.jl")
const BASELINE_PROVENANCE_SOURCE = joinpath(BASELINE_ROOT, "src", "Provenance.jl")
const LEGACY_RESULT_DIR = joinpath(
    BASELINE_ROOT,
    "results_sdp",
    "sweep_wdwe2_k20",
)
const LEGACY_SCORE = joinpath(LEGACY_RESULT_DIR, "score.jld2")
const LEGACY_LOG = joinpath(BASELINE_ROOT, "results_sdp", "sweep_wdwe2_k20.log")
const EXPECTED_LEGACY_MEAN = 0.7676755785921663

function file_snapshot(paths::Vector{String})
    return Dict(
        path => (
            bytes=filesize(path),
            modified=stat(path).mtime,
            sha256=Provenance.sha256_file(path),
        ) for path in paths
    )
end

function file_stat_snapshot(paths::Vector{String})
    return Dict(
        path => (bytes=filesize(path), modified=stat(path).mtime) for path in paths
    )
end

@testset "immutable wdwe2_k20 legacy fixture" begin
    required_sources_exist = isfile(BASELINE_PROVENANCE_SOURCE) &&
                             isfile(BASELINE_CAPTURE_SCRIPT)
    @test required_sources_exist

    fixture_paths = [
        joinpath(BASELINE_DIR, "input-manifest.tsv"),
        joinpath(BASELINE_DIR, "scores.csv"),
        joinpath(BASELINE_DIR, "vf-manifest.tsv"),
        joinpath(BASELINE_DIR, "legacy-source.toml"),
    ]
    fixtures_exist = all(isfile, fixture_paths)
    @test fixtures_exist

    if required_sources_exist && fixtures_exist
        if !isdefined(@__MODULE__, :Provenance)
            include(BASELINE_PROVENANCE_SOURCE)
        end
        include(BASELINE_CAPTURE_SCRIPT)

        @testset "numeric site ordering" begin
            sorter_exists = isdefined(WDWE2BaselineCapture, :sort_sites_numerically!)
            @test sorter_exists
            if sorter_exists
                unordered = DataFrame(
                    site=["10", "2", "1"],
                    cost=[10.0, 2.0, 1.0],
                    gain=zeros(3),
                    score=zeros(3),
                )
                @test WDWE2BaselineCapture.sort_sites_numerically!(unordered) ===
                      unordered
                @test unordered.site == ["1", "2", "10"]
                @test unordered.cost == [1.0, 2.0, 10.0]
            end
        end

        input_manifest, scores_path, vf_manifest, legacy_source_path = fixture_paths

        @testset "144 formal inputs" begin
            lines = readlines(input_manifest)
            @test length(lines) == 145
            @test first(lines) == "path\tbytes\tsha256"
            rows = [split(line, '\t') for line in Iterators.drop(lines, 1)]
            @test all(length(row) == 3 for row in rows)
            relative_paths = first.(rows)
            expected_paths = vcat(
                ["dataset/train/$(site).csv.gz" for site in 1:70],
                ["dataset/test/$(site).csv.gz" for site in 1:70],
                [
                    "dataset/metadata.csv",
                    "EMSx.jl/metadata/edf_prices.csv",
                    "EMSx.jl/metadata/baseline/dummy.jld2",
                    "EMSx.jl/metadata/baseline/anticipative.jld2",
                ],
            )
            @test length(relative_paths) == 144
            @test Set(relative_paths) == Set(expected_paths)
            @test Provenance.verify_file_manifest(input_manifest, BASELINE_ROOT) ===
                  nothing
        end

        @testset "70 exact legacy scores" begin
            scores = CSV.read(
                scores_path,
                DataFrame;
                stringtype=String,
                types=Dict(:site => String),
            )
            @test names(scores) == ["site", "cost", "gain", "score"]
            @test nrow(scores) == 70
            @test scores.site == string.(1:70)
            @test isapprox(
                mean(scores.score),
                EXPECTED_LEGACY_MEAN;
                atol=1e-12,
                rtol=0,
            )
        end

        @testset "70 value-function inventory rows" begin
            inventory = CSV.read(
                vf_manifest,
                DataFrame;
                delim='\t',
                stringtype=String,
            )
            @test names(inventory) == [
                "site",
                "path",
                "bytes",
                "sha256",
                "horizon",
                "soc_points",
                "z_points",
                "alpha_length",
                "beta_length",
                "z_min",
                "z_max",
            ]
            @test nrow(inventory) == 70
            @test inventory.site == collect(1:70)
            @test all(inventory.horizon .== 673)
            @test all(inventory.soc_points .== 11)
            @test all(inventory.z_points .== 20)
            @test all(inventory.alpha_length .== 672)
            @test all(inventory.beta_length .== 672)

            for row in eachrow(inventory)
                path = joinpath(BASELINE_ROOT, row.path)
                @test isfile(path)
                @test filesize(path) == row.bytes
                @test Provenance.sha256_file(path) == row.sha256
                payload = JLD2.load(path)
                @test size(payload["value_function"]) == (673, 11, 20)
                @test length(payload["alpha"]) == 672
                @test length(payload["beta"]) == 672
                @test payload["z_min"] == row.z_min
                @test payload["z_max"] == row.z_max
            end
        end

        @testset "legacy source hashes" begin
            source = TOML.parsefile(legacy_source_path)
            @test source["legacy_environment_lock"] ==
                  "not_recorded_by_legacy_run"
            @test source["legacy_score_path"] == relpath(LEGACY_SCORE, BASELINE_ROOT)
            @test source["legacy_score_sha256"] ==
                  Provenance.sha256_file(LEGACY_SCORE)
            @test source["legacy_log_path"] == relpath(LEGACY_LOG, BASELINE_ROOT)
            @test source["legacy_log_sha256"] == Provenance.sha256_file(LEGACY_LOG)
            @test source["input_manifest_sha256"] ==
                  Provenance.sha256_file(input_manifest)
            @test source["scores_sha256"] == Provenance.sha256_file(scores_path)
            @test source["vf_manifest_sha256"] ==
                  Provenance.sha256_file(vf_manifest)
            @test source["value_function_count"] == 70
        end

        @testset "capture is idempotent and legacy results stay read-only" begin
            legacy_paths = vcat(
                [LEGACY_SCORE, LEGACY_LOG],
                [
                    joinpath(LEGACY_RESULT_DIR, "value_functions", "$(site).jld2") for
                    site in 1:70
                ],
            )
            helper_path =
                joinpath(BASELINE_ROOT, "EMSx.jl", "examples", "sdp", "function.jl")
            protected_inputs = vcat(
                WDWE2BaselineCapture.formal_input_files(),
                [helper_path],
            )
            fixture_before = file_snapshot(fixture_paths)
            legacy_before = file_snapshot(legacy_paths)
            protected_before = file_stat_snapshot(protected_inputs)
            helper_before = file_snapshot([helper_path])
            @test WDWE2BaselineCapture.main() === nothing
            @test file_snapshot(fixture_paths) == fixture_before
            @test file_snapshot(legacy_paths) == legacy_before
            @test file_stat_snapshot(protected_inputs) == protected_before
            @test file_snapshot([helper_path]) == helper_before
            @test Provenance.verify_file_manifest(input_manifest, BASELINE_ROOT) ===
                  nothing
        end

        @testset "fixture set publishes completely and is immutable" begin
            mktempdir() do temp
                final = joinpath(temp, "fixtures")
                contents = Dict(
                    "input-manifest.tsv" => Vector{UInt8}(codeunits("input")),
                    "scores.csv" => Vector{UInt8}(codeunits("scores")),
                    "vf-manifest.tsv" => Vector{UInt8}(codeunits("vf")),
                    "legacy-source.toml" => Vector{UInt8}(codeunits("source")),
                )
                outputs = Dict(joinpath(final, name) => content for (name, content) in contents)
                @test WDWE2BaselineCapture.write_outputs_immutably(outputs) === nothing
                @test sort(readdir(final)) == sort(collect(keys(contents)))
                @test all(read(joinpath(final, name)) == content for (name, content) in contents)
                before = file_snapshot(collect(keys(outputs)))
                @test WDWE2BaselineCapture.write_outputs_immutably(outputs) === nothing
                @test file_snapshot(collect(keys(outputs))) == before
            end
        end

        @testset "partial fixture sets are rejected, never completed" begin
            mktempdir() do temp
                final = joinpath(temp, "fixtures")
                names = ["a", "b", "c", "d"]
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )

                mkpath(final)
                write(joinpath(final, "a"), "A")
                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs,
                )
                @test readdir(final) == ["a"]
                @test read(joinpath(final, "a"), String) == "A"

                empty_final = joinpath(temp, "empty-fixtures")
                empty_outputs = Dict(
                    joinpath(empty_final, name) => content for
                    (name, content) in zip(names, values(outputs))
                )
                mkpath(empty_final)
                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    empty_outputs,
                )
                @test isempty(readdir(empty_final))
            end
        end

        @testset "staged fixture publish failure leaves no final set" begin
            mktempdir() do temp
                final = joinpath(temp, "fixtures")
                names = ["a", "b", "c", "d"]
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )
                staged_complete = Ref(false)
                before_publish = function (staging, target)
                    staged_complete[] =
                        target == final &&
                        sort(readdir(staging)) == names &&
                        all(
                            read(joinpath(staging, name)) == outputs[joinpath(final, name)] for
                            name in names
                        )
                    error("injected publish failure")
                end

                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs;
                    _before_publish=before_publish,
                )
                @test staged_complete[]
                @test !ispath(final)
                @test isempty(readdir(temp))
            end
        end

        @testset "staging is revalidated after the publish callback" begin
            mktempdir() do temp
                final = joinpath(temp, "fixtures")
                names = ["a", "b", "c", "d"]
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )
                callback_called = Ref(false)
                before_publish = function (staging, target)
                    callback_called[] = target == final
                    rm(joinpath(staging, "a"))
                    return nothing
                end

                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs;
                    _before_publish=before_publish,
                )
                @test callback_called[]
                @test !ispath(final)
                @test isempty(readdir(temp))
            end
        end

        @testset "a competing fixture directory wins without being modified" begin
            mktempdir() do temp
                final = joinpath(temp, "fixtures")
                names = ["a", "b", "c", "d"]
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )
                marker = joinpath(final, "competitor")
                before_publish = function (staging, target)
                    @test sort(readdir(staging)) == names
                    @test target == final
                    mkpath(target)
                    write(marker, "competitor")
                    return nothing
                end

                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs;
                    _before_publish=before_publish,
                )
                @test read(marker, String) == "competitor"
                @test readdir(final) == ["competitor"]
                @test readdir(temp) == ["fixtures"]
            end
        end

        @testset "fixture directory symlinks are rejected" begin
            mktempdir() do temp
                external = joinpath(temp, "external")
                final = joinpath(temp, "fixtures")
                names = ["a", "b", "c", "d"]
                mkpath(external)
                for name in names
                    write(joinpath(external, name), uppercase(name))
                end
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )
                external_paths = [joinpath(external, name) for name in names]
                external_before = file_snapshot(external_paths)
                symlink(external, final)

                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs,
                )
                @test islink(final)
                @test file_snapshot(external_paths) == external_before
            end
        end

        @testset "fixture publication rejects a symlinked parent" begin
            mktempdir() do temp
                real_parent = joinpath(temp, "real-parent")
                alias_parent = joinpath(temp, "alias-parent")
                mkpath(real_parent)
                symlink(real_parent, alias_parent)
                final = joinpath(alias_parent, "fixtures")
                names = ["a", "b", "c", "d"]
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )

                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs,
                )
                @test islink(alias_parent)
                @test !ispath(joinpath(real_parent, "fixtures"))
                @test isempty(readdir(real_parent))
            end

            mktempdir() do temp
                real_parent = joinpath(temp, "real-parent")
                alias_parent = joinpath(temp, "alias-parent")
                mkpath(real_parent)
                symlink(real_parent, alias_parent)
                final = joinpath(alias_parent, "new-parent", "fixtures")
                names = ["a", "b", "c", "d"]
                outputs = Dict(
                    joinpath(final, name) => Vector{UInt8}(codeunits(uppercase(name))) for
                    name in names
                )

                @test_throws ErrorException WDWE2BaselineCapture.write_outputs_immutably(
                    outputs,
                )
                @test !ispath(joinpath(real_parent, "new-parent"))
                @test isempty(readdir(real_parent))
            end
        end
    end
end
