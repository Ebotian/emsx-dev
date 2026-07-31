using Distributed
using Test
using TOML

const PROVENANCE_ROOT = normpath(joinpath(@__DIR__, ".."))
const PROVENANCE_SOURCE = joinpath(PROVENANCE_ROOT, "src", "Provenance.jl")

function porcelain_lines(repository::String)
    raw = read(`git -C $repository status --porcelain=v1 --untracked-files=all`, String)
    return isempty(raw) ? String[] : split(chomp(raw), '\n')
end

@testset "provenance" begin
    source_exists = isfile(PROVENANCE_SOURCE)
    @test source_exists

    if source_exists
        include(PROVENANCE_SOURCE)
        @eval using .Provenance

        @testset "SHA-256 and deterministic manifests" begin
            mktempdir() do root
                abc = joinpath(root, "abc.txt")
                write(abc, "abc")
                @test Provenance.sha256_file(abc) ==
                      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

                first_path = joinpath(root, "first.txt")
                second_path = joinpath(root, "nested", "second.txt")
                mkpath(dirname(second_path))
                write(first_path, "first")
                write(second_path, "second")
                manifest = joinpath(root, "manifests", "inputs.tsv")

                manifest_hash = Provenance.write_file_manifest(
                    manifest,
                    [second_path, first_path],
                    root,
                )
                @test manifest_hash == Provenance.sha256_file(manifest)
                @test readlines(manifest) == [
                    "path\tbytes\tsha256",
                    "first.txt\t5\ta7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e",
                    "nested/second.txt\t6\t16367aacb67a4a017c8da8ab95682ccb390863780f7114dda0a0e0c55644c7c4",
                ]

                @test Provenance.verify_file_manifest(manifest, root) === nothing

                write(second_path, "Second")
                @test_throws ErrorException Provenance.verify_file_manifest(manifest, root)

                write(second_path, "second")
                write(manifest, "wrong\theader\n")
                @test_throws ErrorException Provenance.verify_file_manifest(manifest, root)
                @test_throws ErrorException Provenance.write_file_manifest(
                    joinpath(root, "missing.tsv"),
                    [joinpath(root, "absent")],
                    root,
                )
            end
        end

        @testset "manifest writes are atomic and never overwrite" begin
            mktempdir() do temp
                root = joinpath(temp, "root")
                mkpath(root)
                valid = joinpath(root, "valid.txt")
                missing = joinpath(root, "missing.txt")
                write(valid, "valid")

                absent_output = joinpath(root, "absent-output.tsv")
                @test_throws ErrorException Provenance.write_file_manifest(
                    absent_output,
                    [valid, missing],
                    root,
                )
                @test !ispath(absent_output)

                existing_output = joinpath(root, "existing-output.tsv")
                write(existing_output, "preserve-me")
                original = read(existing_output)
                @test_throws Exception Provenance.write_file_manifest(
                    existing_output,
                    [valid, missing],
                    root,
                )
                @test read(existing_output) == original
                @test_throws Exception Provenance.write_file_manifest(
                    existing_output,
                    [valid],
                    root,
                )
                @test read(existing_output) == original

                empty_output = joinpath(root, "empty-output.tsv")
                @test_throws ErrorException Provenance.write_file_manifest(
                    empty_output,
                    String[],
                    root,
                )
                @test !ispath(empty_output)
            end
        end

        @testset "strict canonical manifest grammar and containment" begin
            mktempdir() do temp
                root = joinpath(temp, "root")
                nested = joinpath(root, "nested")
                mkpath(nested)
                path = joinpath(nested, "data.txt")
                write(path, "data")
                digest = Provenance.sha256_file(path)
                valid_row = "nested/data.txt\t4\t$(digest)"
                manifest = joinpath(temp, "manifest.tsv")

                function verify_text(text::String)
                    write(manifest, text)
                    return Provenance.verify_file_manifest(manifest, root)
                end

                @test verify_text("path\tbytes\tsha256\n$(valid_row)\n") === nothing
                invalid_manifests = [
                    "",
                    "path\tbytes\tsha256\n",
                    "path\tbytes\tsha256\n$(valid_row)\textra\n",
                    "path\tbytes\tsha256\n/nested/data.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nC:/nested/data.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/../nested/data.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\n./nested/data.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested//data.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested\\data.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/data.txt\t04\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/data.txt\t-4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/data.txt\t+4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/data.txt\t4\t$(uppercase(digest))\n",
                    "path\tbytes\tsha256\nnested/data.txt\t4\t$(digest[1:63])\n",
                    "path\tbytes\tsha256\n$(valid_row)\n$(valid_row)\n",
                    "path\tbytes\tsha256\nnested/data\tname.txt\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/data.txt\nname\t4\t$(digest)\n",
                    "path\tbytes\tsha256\nnested/data\u0001.txt\t4\t$(digest)\n",
                ]
                for text in invalid_manifests
                    @test_throws Exception verify_text(text)
                end

                outside = joinpath(temp, "outside.txt")
                write(outside, "outside")
                escape_link = joinpath(root, "escape-link")
                symlink(outside, escape_link)
                escape_digest = Provenance.sha256_file(outside)
                @test_throws ErrorException verify_text(
                    "path\tbytes\tsha256\nescape-link\t7\t$(escape_digest)\n",
                )

                inside_link = joinpath(root, "inside-link")
                symlink(path, inside_link)
                @test verify_text(
                    "path\tbytes\tsha256\ninside-link\t4\t$(digest)\n",
                ) === nothing

                fingerprint_exists =
                    isdefined(Provenance, :_contained_file_fingerprint)
                @test fingerprint_exists
                if fingerprint_exists
                    candidate = joinpath(root, "race.txt")
                    write(candidate, "contained")
                    @test_throws ErrorException Provenance._contained_file_fingerprint(
                        candidate,
                        root;
                        _after_open=() -> begin
                            rm(candidate)
                            symlink(outside, candidate)
                        end,
                    )
                end

                duplicate_output = joinpath(temp, "duplicate.tsv")
                @test_throws ErrorException Provenance.write_file_manifest(
                    duplicate_output,
                    [path, path],
                    root,
                )
                @test !ispath(duplicate_output)
                alias_path = joinpath(root, "nested", "..", "nested", "data.txt")
                alias_output = joinpath(temp, "alias.tsv")
                @test_throws ErrorException Provenance.write_file_manifest(
                    alias_output,
                    [alias_path],
                    root,
                )
                @test !ispath(alias_output)
                outside_output = joinpath(temp, "outside.tsv")
                @test_throws ErrorException Provenance.write_file_manifest(
                    outside_output,
                    [outside],
                    root,
                )
                @test !ispath(outside_output)
                symlink_output = joinpath(temp, "symlink.tsv")
                @test_throws ErrorException Provenance.write_file_manifest(
                    symlink_output,
                    [escape_link],
                    root,
                )
                @test !ispath(symlink_output)

                tab_path = joinpath(root, "tab\tname.txt")
                newline_path = joinpath(root, "line\nname.txt")
                write(tab_path, "tab")
                write(newline_path, "line")
                for invalid_path in (tab_path, newline_path)
                    invalid_output = joinpath(temp, "invalid-name-$(rand(UInt)).tsv")
                    @test_throws ErrorException Provenance.write_file_manifest(
                        invalid_output,
                        [invalid_path],
                        root,
                    )
                    @test !ispath(invalid_output)
                end
            end
        end

        @testset "Git state and formal clean-source gate" begin
            for repository in (PROVENANCE_ROOT, joinpath(PROVENANCE_ROOT, "EMSx.jl"))
                state = Provenance.git_state(repository)
                @test state.sha == readchomp(`git -C $repository rev-parse HEAD`)
                @test state.status == porcelain_lines(repository)
                @test state.dirty == !isempty(state.status)
            end

            outer = Provenance.git_state(PROVENANCE_ROOT)
            nested = Provenance.git_state(joinpath(PROVENANCE_ROOT, "EMSx.jl"))
            if outer.dirty || nested.dirty
                @test_throws ErrorException Provenance.assert_formal_sources_clean!(
                    PROVENANCE_ROOT,
                )
            else
                @test Provenance.assert_formal_sources_clean!(PROVENANCE_ROOT) === nothing
            end

            mktempdir() do temp
                clean_root = joinpath(temp, "outer")
                run(`git clone --quiet --no-local $PROVENANCE_ROOT $clean_root`)
                nested_source = joinpath(PROVENANCE_ROOT, "EMSx.jl")
                nested_copy = joinpath(clean_root, "EMSx.jl")
                run(`git clone --quiet --no-local $nested_source $nested_copy`)

                @test Provenance.assert_formal_sources_clean!(clean_root) === nothing

                outer_untracked = joinpath(clean_root, "untracked.txt")
                write(outer_untracked, "dirty outer")
                @test Provenance.git_state(clean_root).dirty
                @test !Provenance.git_state(nested_copy).dirty
                @test_throws ErrorException Provenance.assert_formal_sources_clean!(
                    clean_root,
                )
                rm(outer_untracked)

                nested_untracked = joinpath(nested_copy, "untracked.txt")
                write(nested_untracked, "dirty nested")
                @test !Provenance.git_state(clean_root).dirty
                @test Provenance.git_state(nested_copy).dirty
                @test_throws ErrorException Provenance.assert_formal_sources_clean!(
                    clean_root,
                )
            end
        end

        @testset "complete and immutable provenance record" begin
            @test nprocs() == 1
            mktempdir() do temp
                input_manifest = joinpath(temp, "input-manifest.tsv")
                vf_manifest = joinpath(temp, "vf-manifest.tsv")
                write(input_manifest, "path\tbytes\tsha256\n")
                write(vf_manifest, "site\tpath\tbytes\tsha256\n")
                output = joinpath(temp, "nested", "provenance.toml")
                parameters = Dict{String,Any}("workers" => 0, "sites" => 70)

                @test Provenance.capture_provenance(
                    output;
                    root=PROVENANCE_ROOT,
                    phase="test",
                    tag="task-4",
                    run_id="zero-workers",
                    parameters=parameters,
                    input_manifest=input_manifest,
                    vf_manifest=vf_manifest,
                ) === nothing

                record = TOML.parsefile(output)
                expected_keys = Set([
                    "schema_version",
                    "captured_at_utc",
                    "phase",
                    "tag",
                    "run_id",
                    "julia_version",
                    "cpu_name",
                    "cpu_threads",
                    "julia_threads",
                    "blas_threads",
                    "blas_config",
                    "active_project",
                    "emsx_path",
                    "load_path",
                    "outer_git_sha",
                    "outer_git_dirty",
                    "nested_git_sha",
                    "nested_git_dirty",
                    "project_sha256",
                    "manifest_sha256",
                    "input_manifest",
                    "input_manifest_sha256",
                    "vf_manifest",
                    "vf_manifest_sha256",
                    "parameters",
                    "workers",
                ])
                @test Set(keys(record)) == expected_keys
                @test record["schema_version"] == 1
                @test record["parameters"] == parameters
                @test isempty(record["workers"])
                outer = Provenance.git_state(PROVENANCE_ROOT)
                nested = Provenance.git_state(joinpath(PROVENANCE_ROOT, "EMSx.jl"))
                @test record["outer_git_sha"] == outer.sha
                @test record["outer_git_dirty"] == outer.dirty
                @test record["nested_git_sha"] == nested.sha
                @test record["nested_git_dirty"] == nested.dirty
                @test record["input_manifest_sha256"] ==
                      Provenance.sha256_file(input_manifest)
                @test record["vf_manifest_sha256"] ==
                      Provenance.sha256_file(vf_manifest)

                original = read(output)
                @test_throws Exception Provenance.capture_provenance(
                    output;
                    root=PROVENANCE_ROOT,
                    phase="changed",
                    tag="changed",
                    run_id="changed",
                    parameters=Dict{String,Any}(),
                    input_manifest=input_manifest,
                    vf_manifest=nothing,
                )
                @test read(output) == original
            end
        end

        @testset "nonzero worker identity is captured in an isolated process" begin
            @test nprocs() == 1
            mktempdir() do temp
                input_manifest = joinpath(temp, "input-manifest.tsv")
                output = joinpath(temp, "provenance.toml")
                script = joinpath(temp, "capture-worker-provenance.jl")
                write(input_manifest, "path\tbytes\tsha256\n")
                write(
                    script,
                    """
                    using Distributed
                    using TOML

                    const ROOT = $(repr(PROVENANCE_ROOT))
                    include(joinpath(ROOT, "src", "EnvironmentIdentity.jl"))
                    include(joinpath(ROOT, "src", "Provenance.jl"))
                    using .EnvironmentIdentity
                    using .Provenance

                    worker_ids = Int[]
                    try
                        append!(worker_ids, EnvironmentIdentity.start_workers_checked!(ROOT, 1))
                        Provenance.capture_provenance(
                            ARGS[1];
                            root=ROOT,
                            phase="test",
                            tag="task-4",
                            run_id="one-worker",
                            parameters=Dict{String,Any}("workers" => 1),
                            input_manifest=ARGS[2],
                        )
                    finally
                        isempty(worker_ids) || rmprocs(worker_ids)
                    end
                    """,
                )

                launcher = joinpath(PROVENANCE_ROOT, "scripts", "julia_locked.sh")
                run(`$launcher $script $output $input_manifest`)
                record = TOML.parsefile(output)
                @test length(record["workers"]) == 1
                worker = only(record["workers"])
                @test worker["worker"] > 1
                @test realpath(worker["project"]) ==
                      realpath(joinpath(PROVENANCE_ROOT, "Project.toml"))
                @test realpath(worker["emsx"]) == realpath(
                    joinpath(PROVENANCE_ROOT, "EMSx.jl", "src", "EMSx.jl"),
                )
                @test worker["load_path"] == ["@", "@stdlib"]
            end
            @test nprocs() == 1
        end

        @testset "provenance serialization and install failures are atomic" begin
            mktempdir() do temp
                input_manifest = joinpath(temp, "input-manifest.tsv")
                write(input_manifest, "path\tbytes\tsha256\n")

                bad_output = joinpath(temp, "bad", "provenance.toml")
                @test_throws ErrorException Provenance.capture_provenance(
                    bad_output;
                    root=PROVENANCE_ROOT,
                    phase="test",
                    tag="task-4",
                    run_id="unserializable",
                    parameters=Dict{String,Any}("bad" => nothing),
                    input_manifest=input_manifest,
                )
                @test !ispath(bad_output)
                @test !ispath(dirname(bad_output))

                forbidden_output = joinpath(temp, "forbidden", "provenance.toml")
                @test_throws MethodError Provenance.capture_provenance(
                    forbidden_output;
                    root=PROVENANCE_ROOT,
                    phase="test",
                    tag="task-4",
                    run_id="public-hook-forbidden",
                    parameters=Dict{String,Any}("workers" => 0),
                    input_manifest=input_manifest,
                    _before_install=() -> nothing,
                )
                @test !ispath(forbidden_output)

                atomic_helper_exists = isdefined(Provenance, :_atomic_write_new)
                @test atomic_helper_exists
                if atomic_helper_exists
                    conflict_dir = joinpath(temp, "conflict")
                    conflict_output = joinpath(conflict_dir, "provenance.toml")
                    callback_called = Ref(false)
                    staged_name_hidden = Ref(false)
                    competitor = Vector{UInt8}(codeunits("competitor"))
                    payload = Vector{UInt8}(codeunits("generated"))
                    before_stage = function (parent, target)
                        callback_called[] = true
                        @test parent == conflict_dir
                        @test target == conflict_output
                        staged_name_hidden[] = isempty(
                            filter(name -> startswith(name, "jl_"), readdir(parent)),
                        )
                        write(target, competitor)
                    end

                    @test_throws Exception Provenance._atomic_write_new(
                        conflict_output,
                        payload;
                        _before_stage=before_stage,
                    )
                    @test callback_called[]
                    @test staged_name_hidden[]
                    conflict_exists = isfile(conflict_output)
                    @test conflict_exists
                    if conflict_exists
                        @test read(conflict_output) == competitor
                        @test readdir(conflict_dir) == ["provenance.toml"]
                    end
                end
            end
        end

        @testset "manifest snapshots support selected and complete verification" begin
            snapshot_api_exists = all(
                isdefined(Provenance, name) for name in (
                    :ManifestSnapshot,
                    :capture_manifest_snapshot,
                    :select_manifest_entries,
                    :verify_manifest_entries,
                    :verify_manifest_snapshot,
                )
            )
            @test snapshot_api_exists
            if snapshot_api_exists
                mktempdir() do temp
                    root = joinpath(temp, "root")
                    data = joinpath(root, "nested", "data.txt")
                    mkpath(dirname(data))
                    write(data, "data")
                    manifest = joinpath(root, "manifest.tsv")
                    Provenance.write_file_manifest(manifest, [data], root)
                    snapshot = Provenance.capture_manifest_snapshot(manifest, root)

                    @test snapshot.manifest_path == normpath(realpath(manifest))
                    @test snapshot.manifest_sha256 == Provenance.sha256_file(manifest)
                    @test snapshot.entries isa Tuple
                    @test [(entry.path, entry.bytes, entry.sha256) for entry in snapshot.entries] == [
                        (
                            "nested/data.txt",
                            4,
                            "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
                        ),
                    ]
                    selected = Provenance.select_manifest_entries(
                        snapshot,
                        ["nested/data.txt"],
                    )
                    @test selected == collect(snapshot.entries)
                    @test Provenance.verify_manifest_entries(snapshot, selected) === nothing
                    @test Provenance.verify_manifest_snapshot(snapshot) === nothing
                    @test_throws ErrorException Provenance.select_manifest_entries(
                        snapshot,
                        ["missing.txt"],
                    )

                    stable_content_api_exists =
                        isdefined(Provenance, :_contained_file_content)
                    @test stable_content_api_exists
                    if stable_content_api_exists
                        observation = Provenance._contained_file_content(
                            manifest,
                            dirname(manifest),
                        )
                        @test observation.content == read(manifest)
                        @test observation.sha256 == snapshot.manifest_sha256
                        race_manifest = joinpath(root, "read-race-manifest.tsv")
                        write(race_manifest, read(manifest))
                        original_manifest = read(race_manifest)
                        @test_throws ErrorException Provenance._contained_file_content(
                            race_manifest,
                            root;
                            _after_read=() -> begin
                                rm(race_manifest)
                                write(race_manifest, original_manifest)
                            end,
                        )
                    end

                    snapshot_impl_exists =
                        isdefined(Provenance, :_verify_manifest_snapshot_impl)
                    @test snapshot_impl_exists
                    if snapshot_impl_exists
                        race_manifest = joinpath(root, "verify-race-manifest.tsv")
                        Provenance.write_file_manifest(race_manifest, [data], root)
                        race_snapshot =
                            Provenance.capture_manifest_snapshot(race_manifest, root)
                        original_manifest = read(race_manifest)
                        @test_throws ErrorException Provenance._verify_manifest_snapshot_impl(
                            race_snapshot;
                            _before_final_manifest_check=() -> begin
                                rm(race_manifest)
                                write(race_manifest, original_manifest)
                            end,
                        )
                    end

                    write(data, "DATA")
                    @test_throws ErrorException Provenance.verify_manifest_entries(
                        snapshot,
                        selected,
                    )

                    manifest_link = joinpath(temp, "manifest-link.tsv")
                    symlink(manifest, manifest_link)
                    @test_throws ErrorException Provenance.capture_manifest_snapshot(
                        manifest_link,
                        root,
                    )
                end
            end
        end

        @testset "stable file guards reject replacement and symlink changes" begin
            stable_guard_api_exists = all(
                isdefined(Provenance, name) for name in (
                    :capture_stable_file_guard,
                    :verify_stable_file_guard,
                )
            )
            @test stable_guard_api_exists
            if stable_guard_api_exists
                mktempdir() do temp
                    root = joinpath(temp, "root")
                    data = joinpath(root, "data.txt")
                    mkpath(root)
                    write(data, "stable")
                    guard = Provenance.capture_stable_file_guard(data, root)
                    @test all(
                        field -> hasproperty(guard, field),
                        (
                            :path,
                            :physical,
                            :device,
                            :inode,
                            :mode,
                            :size,
                            :mtime,
                            :ctime,
                            :bytes,
                            :sha256,
                            :components,
                        ),
                    )
                    @test guard.physical == realpath(data)
                    @test guard.bytes == 6
                    @test guard.sha256 == Provenance.sha256_file(data)
                    @test Provenance.verify_stable_file_guard(guard) === nothing

                    original_mode = stat(data).mode & 0o777
                    changed_mode = original_mode == 0o600 ? 0o644 : 0o600
                    chmod(data, changed_mode)
                    @test_throws ErrorException Provenance.verify_stable_file_guard(guard)
                    chmod(data, original_mode)

                    rm(data)
                    write(data, "stable")
                    @test_throws ErrorException Provenance.verify_stable_file_guard(guard)

                    target_one = joinpath(root, "target-one")
                    target_two = joinpath(root, "target-two")
                    mkpath(target_one)
                    mkpath(target_two)
                    write(joinpath(target_one, "data.txt"), "stable")
                    write(joinpath(target_two, "data.txt"), "stable")
                    component = joinpath(root, "selected")
                    symlink(target_one, component)
                    component_guard = Provenance.capture_stable_file_guard(
                        joinpath(component, "data.txt"),
                        root,
                    )
                    rm(component)
                    symlink(target_two, component)
                    @test_throws ErrorException Provenance.verify_stable_file_guard(
                        component_guard,
                    )

                    physical_parent = joinpath(temp, "physical-parent")
                    physical_root = joinpath(physical_parent, "root")
                    mkpath(physical_root)
                    physical_data = joinpath(physical_root, "data.txt")
                    write(physical_data, "stable")
                    parent_alias = joinpath(temp, "parent-alias")
                    symlink(physical_parent, parent_alias)
                    aliased_root = joinpath(parent_alias, "root")
                    aliased_data = joinpath(aliased_root, "data.txt")
                    ancestor_guard = Provenance.capture_stable_file_guard(
                        aliased_data,
                        aliased_root,
                    )
                    rm(parent_alias)
                    symlink(physical_parent, parent_alias)
                    @test_throws ErrorException Provenance.verify_stable_file_guard(
                        ancestor_guard,
                    )
                end
            end
        end
    end
end
