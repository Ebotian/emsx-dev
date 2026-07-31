module Provenance

using Dates
using Distributed
using EMSx
using LinearAlgebra
using SHA
using TOML

export sha256_file, git_state, write_file_manifest, verify_file_manifest
export ManifestSnapshot, capture_manifest_snapshot, select_manifest_entries
export verify_manifest_entries, verify_manifest_snapshot
export capture_stable_file_guard, verify_stable_file_guard
export assert_formal_sources_clean!, capture_provenance

sha256_file(path::String) = bytes2hex(open(SHA.sha256, path))

function git_state(repository::String)
    sha = readchomp(`git -C $repository rev-parse HEAD`)
    raw = read(`git -C $repository status --porcelain=v1 --untracked-files=all`, String)
    status = isempty(raw) ? String[] : split(chomp(raw), '\n')
    return (sha=sha, dirty=!isempty(status), status=status)
end

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const BYTE_COUNT_PATTERN = r"^(0|[1-9][0-9]*)$"
const WINDOWS_DRIVE_PATTERN = r"^[A-Za-z]:"

function _is_contained(path::String, root::String)
    relative = relpath(path, root)
    return !isabspath(relative) &&
           relative != ".." &&
           !startswith(relative, "..$(Base.Filesystem.path_separator)")
end

function _portable_relative_parts(relative::AbstractString)
    isempty(relative) && error("manifest path is empty")
    isabspath(relative) && error("manifest path is absolute: $(relative)")
    occursin(WINDOWS_DRIVE_PATTERN, relative) &&
        error("manifest path has a Windows drive prefix: $(relative)")
    occursin('\\', relative) &&
        error("manifest path uses a non-portable separator: $(relative)")
    any(iscntrl, relative) && error("manifest path contains a control character")
    parts = split(relative, '/'; keepempty=true)
    any(isempty, parts) && error("manifest path contains an empty component: $(relative)")
    any(part -> part == "." || part == "..", parts) &&
        error("manifest path is not canonical: $(relative)")
    join(parts, '/') == relative || error("manifest path is not canonical: $(relative)")
    return parts
end

function _validate_input_spelling(path::String)
    any(iscntrl, path) && error("input path contains a control character")
    !Sys.iswindows() && occursin('\\', path) &&
        error("input path uses a non-portable separator: $(path)")
    normpath(path) == path || error("input path is not canonical: $(path)")
    return nothing
end

_same_file(left, right) =
    left.device == right.device && left.inode == right.inode

function _same_snapshot(left, right)
    return _same_file(left, right) &&
           left.mode == right.mode &&
           left.size == right.size &&
           left.mtime == right.mtime &&
           left.ctime == right.ctime
end

const ManifestEntry = NamedTuple{(:path, :bytes, :sha256),Tuple{String,Int,String}}

struct ManifestSnapshot
    manifest_path::String
    root::String
    manifest_sha256::String
    entries::Tuple{Vararg{ManifestEntry}}
    manifest_guard::Any
end

function _component_snapshots(path::String, root::String)
    lexical = normpath(abspath(path))
    root_absolute = normpath(abspath(root))
    _is_contained(lexical, root_absolute) ||
        error("manifest input escapes root: $(path)")
    parts = splitpath(lexical)
    components = String[first(parts)]
    current = first(parts)
    for part in Iterators.drop(parts, 1)
        current = joinpath(current, part)
        push!(components, current)
    end
    snapshots = NamedTuple[]
    for component in components
        metadata = lstat(component)
        push!(
            snapshots,
            (
                path=component,
                device=metadata.device,
                inode=metadata.inode,
                mode=metadata.mode,
                size=metadata.size,
                mtime=metadata.mtime,
                ctime=metadata.ctime,
            ),
        )
    end
    return snapshots
end

function _same_component_snapshots(left, right)
    length(left) == length(right) || return false
    for index in eachindex(left)
        left[index].path == right[index].path || return false
        _same_file(left[index], right[index]) || return false
        left[index].mode == right[index].mode || return false
    end
    return true
end

function _canonical_non_symlink_file(path::String, label::String)
    lexical = normpath(abspath(path))
    isfile(lexical) || error("missing $(label): $(path)")
    physical = realpath(lexical)
    physical == lexical || error("$(label) must be a canonical non-symlink path: $(path)")
    return lexical
end

function _contained_file_fingerprint(
    path::String,
    root::String;
    _after_open::Function=() -> nothing,
)
    isdir(root) || error("manifest root is not a directory: $(root)")
    root_absolute = normpath(abspath(root))
    root_physical = realpath(root_absolute)
    lexical = normpath(abspath(path))
    _is_contained(lexical, root_absolute) || error("manifest input escapes root: $(path)")
    isfile(path) || error("missing input: $(path)")

    return open(path, "r") do io
        opened_before = stat(io)
        components_before = _component_snapshots(lexical, root_absolute)
        _after_open()
        physical_before = realpath(path)
        _is_contained(physical_before, root_physical) ||
            error("manifest input escapes root through a symlink: $(path)")
        named_before = stat(path)
        _same_file(opened_before, named_before) ||
            error("manifest input changed while opening: $(path)")

        digest = bytes2hex(SHA.sha256(io))
        opened_after = stat(io)
        physical_after = realpath(path)
        _is_contained(physical_after, root_physical) ||
            error("manifest input escaped root while hashing: $(path)")
        named_after = stat(path)
        _same_snapshot(opened_before, opened_after) ||
            error("manifest input changed while hashing: $(path)")
        _same_snapshot(named_before, named_after) ||
            error("manifest input path changed while hashing: $(path)")
        _same_file(opened_after, named_after) ||
            error("manifest input path changed while hashing: $(path)")
        physical_before == physical_after ||
            error("manifest input symlink changed while hashing: $(path)")
        components_after = _component_snapshots(lexical, root_absolute)
        _same_component_snapshots(components_before, components_after) ||
            error("manifest input path components changed while hashing: $(path)")
        return (
            bytes=opened_before.size,
            sha256=digest,
            physical=physical_before,
            device=opened_before.device,
            inode=opened_before.inode,
            mode=opened_before.mode,
            size=opened_before.size,
            mtime=opened_before.mtime,
            ctime=opened_before.ctime,
            components=components_before,
        )
    end
end

function _contained_file_content(
    path::String,
    root::String;
    _after_read::Function=() -> nothing,
)
    isdir(root) || error("manifest root is not a directory: $(root)")
    root_absolute = normpath(abspath(root))
    root_physical = realpath(root_absolute)
    lexical = normpath(abspath(path))
    _is_contained(lexical, root_absolute) || error("manifest input escapes root: $(path)")
    isfile(path) || error("missing input: $(path)")

    return open(path, "r") do io
        opened_before = stat(io)
        components_before = _component_snapshots(lexical, root_absolute)
        physical_before = realpath(path)
        _is_contained(physical_before, root_physical) ||
            error("manifest input escapes root through a symlink: $(path)")
        named_before = stat(path)
        _same_file(opened_before, named_before) ||
            error("manifest input changed while opening: $(path)")

        content = read(io)
        digest = bytes2hex(SHA.sha256(content))
        _after_read()
        opened_after = stat(io)
        physical_after = realpath(path)
        _is_contained(physical_after, root_physical) ||
            error("manifest input escaped root while reading: $(path)")
        named_after = stat(path)
        _same_snapshot(opened_before, opened_after) ||
            error("manifest input changed while reading: $(path)")
        _same_snapshot(named_before, named_after) ||
            error("manifest input path changed while reading: $(path)")
        _same_file(opened_after, named_after) ||
            error("manifest input path changed while reading: $(path)")
        physical_before == physical_after ||
            error("manifest input symlink changed while reading: $(path)")
        components_after = _component_snapshots(lexical, root_absolute)
        _same_component_snapshots(components_before, components_after) ||
            error("manifest input path components changed while reading: $(path)")
        return (
            content=content,
            bytes=opened_before.size,
            sha256=digest,
            physical=physical_before,
            device=opened_before.device,
            inode=opened_before.inode,
            mode=opened_before.mode,
            size=opened_before.size,
            mtime=opened_before.mtime,
            ctime=opened_before.ctime,
            components=components_before,
        )
    end
end

function _stable_file_guard_from_observation(path::String, root::String, observation)
    return (
        path=normpath(abspath(path)),
        root=normpath(abspath(root)),
        physical=observation.physical,
        device=observation.device,
        inode=observation.inode,
        mode=observation.mode,
        size=observation.size,
        mtime=observation.mtime,
        ctime=observation.ctime,
        bytes=observation.bytes,
        sha256=observation.sha256,
        components=observation.components,
    )
end

function _verify_stable_file_observation(guard, observation)
    observation.physical == guard.physical ||
        error("stable file physical path changed: $(guard.path)")
    for field in (:device, :inode, :mode, :size, :mtime, :ctime, :bytes, :sha256)
        getproperty(observation, field) == getproperty(guard, field) ||
            error("stable file $(field) changed: $(guard.path)")
    end
    _same_component_snapshots(observation.components, guard.components) ||
        error("stable file path components changed: $(guard.path)")
    return nothing
end

function capture_stable_file_guard(path::String, root::String)
    root_absolute = normpath(abspath(root))
    lexical = normpath(abspath(path))
    observation = _contained_file_fingerprint(lexical, root_absolute)
    return _stable_file_guard_from_observation(lexical, root_absolute, observation)
end

function verify_stable_file_guard(guard)
    observation = _contained_file_fingerprint(guard.path, guard.root)
    _verify_stable_file_observation(guard, observation)
    return nothing
end

function _atomic_write_new(
    output::String,
    content::Vector{UInt8};
    staging_directory::Union{Nothing,String}=nothing,
    _before_stage::Function=(parent, target) -> nothing,
)
    Sys.islinux() ||
        error("atomic no-overwrite evidence installation requires Linux")
    target = abspath(output)
    parent = dirname(target)
    mkpath(parent)
    _before_stage(parent, target)
    staging = staging_directory === nothing ? parent : normpath(abspath(staging_directory))
    islink(staging) && error("evidence staging directory must not be a symlink: $(staging)")
    mkpath(staging)
    temporary, io = mktemp(staging)
    try
        write(io, content)
        flush(io)
        close(io)
        Base.Filesystem.hardlink(temporary, target)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    return nothing
end

function write_file_manifest(
    output::String,
    files::Vector{String},
    root::String;
    staging_directory::Union{Nothing,String}=nothing,
)
    isempty(files) && error("file manifest must contain at least one input")
    isdir(root) || error("manifest root is not a directory: $(root)")
    root_absolute = normpath(abspath(root))
    entries = NamedTuple{(:path, :bytes, :sha256),Tuple{String,Int,String}}[]
    seen = Set{String}()

    for path in files
        _validate_input_spelling(path)
        lexical = normpath(abspath(path))
        _is_contained(lexical, root_absolute) ||
            error("manifest input escapes root: $(path)")
        relative = replace(relpath(lexical, root_absolute), '\\' => '/')
        _portable_relative_parts(relative)
        relative in seen && error("duplicate manifest path: $(relative)")
        push!(seen, relative)
        fingerprint = _contained_file_fingerprint(path, root)
        push!(
            entries,
            (
                path=relative,
                bytes=fingerprint.bytes,
                sha256=fingerprint.sha256,
            ),
        )
    end
    sort!(entries; by=entry -> entry.path)

    io = IOBuffer()
    println(io, "path\tbytes\tsha256")
    for entry in entries
        println(io, "$(entry.path)\t$(entry.bytes)\t$(entry.sha256)")
    end
    content = take!(io)
    _atomic_write_new(output, content; staging_directory=staging_directory)
    return bytes2hex(SHA.sha256(content))
end

function _parse_manifest_content(content::String, root::String)
    endswith(content, '\n') || error("manifest must end with a newline")
    lines = split(content, '\n'; keepempty=true)
    isempty(last(lines)) || error("invalid manifest line ending")
    pop!(lines)
    length(lines) >= 2 || error("file manifest contains no data rows")
    first(lines) == "path\tbytes\tsha256" || error("invalid manifest header")

    root_absolute = normpath(abspath(root))
    seen = Set{String}()
    entries = ManifestEntry[]
    for line in Iterators.drop(lines, 1)
        fields = split(line, '\t'; keepempty=true)
        length(fields) == 3 || error("invalid manifest row field count")
        relative, bytes_text, expected = fields
        parts = _portable_relative_parts(relative)
        relative in seen && error("duplicate manifest path: $(relative)")
        push!(seen, relative)
        occursin(BYTE_COUNT_PATTERN, bytes_text) ||
            error("invalid byte count: $(bytes_text)")
        occursin(SHA256_PATTERN, expected) || error("invalid SHA-256: $(expected)")
        bytes = parse(Int, bytes_text)
        path = joinpath(root_absolute, parts...)
        _is_contained(path, root_absolute) ||
            error("manifest path escapes root: $(relative)")
        push!(entries, (path=relative, bytes=bytes, sha256=expected))
    end
    return entries
end

function _verify_manifest_entries(root::String, entries)
    root_absolute = normpath(abspath(root))
    for entry in entries
        parts = _portable_relative_parts(entry.path)
        path = joinpath(root_absolute, parts...)
        _is_contained(path, root_absolute) ||
            error("manifest path escapes root: $(entry.path)")
        fingerprint = _contained_file_fingerprint(path, root)
        fingerprint.bytes == entry.bytes || error("size mismatch: $(entry.path)")
        fingerprint.sha256 == entry.sha256 || error("hash mismatch: $(entry.path)")
    end
    return nothing
end

function verify_file_manifest(manifest::String, root::String)
    isdir(root) || error("manifest root is not a directory: $(root)")
    manifest_path = normpath(abspath(manifest))
    manifest_root = dirname(manifest_path)
    observation = _contained_file_content(manifest_path, manifest_root)
    manifest_guard = _stable_file_guard_from_observation(
        manifest_path,
        manifest_root,
        observation,
    )
    entries = _parse_manifest_content(String(observation.content), root)
    _verify_manifest_entries(root, entries)
    verify_stable_file_guard(manifest_guard)
    return nothing
end

function capture_manifest_snapshot(manifest::String, root::String)
    isdir(root) || error("manifest root is not a directory: $(root)")
    manifest_path = _canonical_non_symlink_file(manifest, "manifest")
    manifest_root = dirname(manifest_path)
    root_absolute = normpath(abspath(root))
    observation = _contained_file_content(manifest_path, manifest_root)
    observation.physical == manifest_path ||
        error("manifest must remain a canonical non-symlink path: $(manifest)")
    _canonical_non_symlink_file(manifest_path, "manifest") == manifest_path ||
        error("manifest path changed: $(manifest)")
    manifest_guard = _stable_file_guard_from_observation(
        manifest_path,
        manifest_root,
        observation,
    )
    entries = Tuple(
        _parse_manifest_content(String(observation.content), root_absolute),
    )
    _verify_manifest_entries(root_absolute, entries)
    verify_stable_file_guard(manifest_guard)
    _canonical_non_symlink_file(manifest_path, "manifest") == manifest_path ||
        error("manifest path changed: $(manifest)")
    return ManifestSnapshot(
        manifest_path,
        root_absolute,
        observation.sha256,
        entries,
        manifest_guard,
    )
end

function select_manifest_entries(
    snapshot::ManifestSnapshot,
    paths::AbstractVector{<:AbstractString},
)
    requested = Set{String}()
    for path in paths
        _portable_relative_parts(path)
        path in requested && error("duplicate selected manifest path: $(path)")
        push!(requested, String(path))
    end
    available = Set(entry.path for entry in snapshot.entries)
    requested ⊆ available ||
        error("selected manifest path is not present in snapshot")
    return [entry for entry in snapshot.entries if entry.path in requested]
end

function verify_manifest_entries(snapshot::ManifestSnapshot, entries)
    expected = Dict(entry.path => entry for entry in snapshot.entries)
    selected_paths = Set{String}()
    for entry in entries
        entry.path in selected_paths &&
            error("duplicate selected manifest path: $(entry.path)")
        push!(selected_paths, entry.path)
        get(expected, entry.path, nothing) == entry ||
            error("selected manifest entry differs from snapshot: $(entry.path)")
    end
    _verify_manifest_entries(snapshot.root, entries)
    return nothing
end

function _verify_manifest_snapshot_impl(
    snapshot::ManifestSnapshot;
    _before_final_manifest_check::Function=() -> nothing,
)
    _canonical_non_symlink_file(snapshot.manifest_path, "manifest") ==
        snapshot.manifest_path || error("manifest path changed: $(snapshot.manifest_path)")
    observation = _contained_file_content(
        snapshot.manifest_path,
        dirname(snapshot.manifest_path),
    )
    _verify_stable_file_observation(snapshot.manifest_guard, observation)
    observation.sha256 == snapshot.manifest_sha256 ||
        error("manifest content SHA-256 changed: $(snapshot.manifest_path)")
    current_entries = Tuple(
        _parse_manifest_content(String(observation.content), snapshot.root),
    )
    current_entries == snapshot.entries ||
        error("manifest entries changed: $(snapshot.manifest_path)")
    _verify_manifest_entries(snapshot.root, snapshot.entries)
    _before_final_manifest_check()
    _canonical_non_symlink_file(snapshot.manifest_path, "manifest") ==
        snapshot.manifest_path || error("manifest path changed: $(snapshot.manifest_path)")
    verify_stable_file_guard(snapshot.manifest_guard)
    return nothing
end

verify_manifest_snapshot(snapshot::ManifestSnapshot) =
    _verify_manifest_snapshot_impl(snapshot)

function assert_formal_sources_clean!(root::String)
    outer = git_state(root)
    nested = git_state(joinpath(root, "EMSx.jl"))
    outer.dirty && error("outer repository is dirty: $(outer.status)")
    nested.dirty && error("nested EMSx repository is dirty: $(nested.status)")
    return nothing
end

function capture_provenance(
    output::String;
    root::String,
    phase::String,
    tag::String,
    run_id::String,
    parameters::Dict{String,Any},
    input_manifest::String,
    vf_manifest::Union{Nothing,String}=nothing,
    staging_directory::Union{Nothing,String}=nothing,
)
    outer = git_state(root)
    nested = git_state(joinpath(root, "EMSx.jl"))
    worker_identity = Dict{String,Any}[]
    worker_ids = nprocs() == 1 ? Int[] : workers()
    for worker in worker_ids
        identity = remotecall_fetch(
            Core.eval,
            worker,
            Main,
            quote
                using Distributed
                using EMSx
                Dict(
                    "worker" => Distributed.myid(),
                    "project" => Base.active_project(),
                    "emsx" => pathof(EMSx),
                    "load_path" => copy(LOAD_PATH),
                )
            end,
        )
        push!(worker_identity, identity)
    end

    record = Dict{String,Any}(
        "schema_version" => 1,
        "captured_at_utc" => string(Dates.now(Dates.UTC)),
        "phase" => phase,
        "tag" => tag,
        "run_id" => run_id,
        "julia_version" => string(VERSION),
        "cpu_name" => Sys.CPU_NAME,
        "cpu_threads" => Sys.CPU_THREADS,
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "blas_config" => sprint(show, LinearAlgebra.BLAS.get_config()),
        "active_project" => Base.active_project(),
        "emsx_path" => pathof(EMSx),
        "load_path" => copy(LOAD_PATH),
        "outer_git_sha" => outer.sha,
        "outer_git_dirty" => outer.dirty,
        "nested_git_sha" => nested.sha,
        "nested_git_dirty" => nested.dirty,
        "project_sha256" => sha256_file(joinpath(root, "Project.toml")),
        "manifest_sha256" => sha256_file(joinpath(root, "Manifest.toml")),
        "input_manifest" => relpath(input_manifest, root),
        "input_manifest_sha256" => sha256_file(input_manifest),
        "vf_manifest" => vf_manifest === nothing ? "" : relpath(vf_manifest, root),
        "vf_manifest_sha256" =>
            vf_manifest === nothing ? "" : sha256_file(vf_manifest),
        "parameters" => parameters,
        "workers" => worker_identity,
    )
    io = IOBuffer()
    TOML.print(io, record; sorted=true)
    content = take!(io)
    _atomic_write_new(output, content; staging_directory=staging_directory)
    return nothing
end

end
