module RunContract

using SHA
using TOML

export with_run_lock, reserve_run!, mark_complete!, assert_complete!, fingerprint

const SCHEMA_VERSION = 1
const INCOMPLETE_STATE = "incomplete"
const COMPLETE_STATE = "complete"
const VALID_PHASES = Set(("calibrate", "simulate", "evaluate"))
const LOCK_EX = Cint(2)
const LOCK_NB = Cint(4)
const LOCK_UN = Cint(8)
const RENAME_NOREPLACE = UInt32(1)
const AT_FDCWD = Cint(-100)
const STAGING_PREFIX = ".emsx-task5-staging-"

mutable struct RunLease
end

const ACTIVE_LEASES = IdDict{RunLease,Tuple{String,IO}}()
const LEASE_REGISTRY_LOCK = ReentrantLock()

function fingerprint(config::Dict)
    io = IOBuffer()
    TOML.print(io, config; sorted=true)
    return bytes2hex(SHA.sha256(take!(io)))
end

function validate_component(value::String, name::String)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", value) ||
        error("invalid $(name): $(value)")
    return value
end

function _require_linux(feature::String)
    Sys.islinux() || error("$(feature) requires Linux")
    return nothing
end

function _lock_path(path::String)
    return joinpath(dirname(path), ".$(basename(path)).lock")
end

function _flock(io::IO, operation::Cint, path::String)
    result = ccall(:flock, Cint, (Cint, Cint), fd(io), operation)
    result == 0 && return nothing
    error("run lease operation failed for $(path): $(Base.Libc.strerror(Base.Libc.errno()))")
end

function _register_lease(lease::RunLease, path::String, io::IO)
    lock(LEASE_REGISTRY_LOCK) do
        ACTIVE_LEASES[lease] = (path, io)
    end
    return nothing
end

function _unregister_lease(lease::RunLease)
    lock(LEASE_REGISTRY_LOCK) do
        haskey(ACTIVE_LEASES, lease) && delete!(ACTIVE_LEASES, lease)
    end
    return nothing
end

function with_run_lock(f::Function, path::String)
    _require_linux("run leases")
    target = normpath(abspath(path))
    parent = dirname(target)
    mkpath(parent)
    lock_path = _lock_path(target)
    islink(lock_path) && error("run lock must not be a symlink: $(lock_path)")

    io = open(lock_path, "a+")
    locked = false
    lease = nothing
    try
        _flock(io, LOCK_EX | LOCK_NB, target)
        locked = true
        lease = RunLease()
        _register_lease(lease, target, io)
        return f(lease)
    finally
        lease === nothing || _unregister_lease(lease)
        try
            locked && isopen(io) && _flock(io, LOCK_UN, target)
        finally
            isopen(io) && close(io)
        end
    end
end

function _lease_path(lease::RunLease)
    entry = lock(LEASE_REGISTRY_LOCK) do
        get(ACTIVE_LEASES, lease, nothing)
    end
    entry === nothing && error("run lease is no longer active")
    isopen(entry[2]) || error("run lease file descriptor is closed")
    return entry[1]
end

function _config_phase(config::Dict)
    haskey(config, "phase") || error("run config is missing phase")
    phase = config["phase"]
    phase isa String || error("run config phase must be a string")
    phase in VALID_PHASES || error("invalid run config phase: $(phase)")
    return phase
end

function _validate_sha256(value, name::String)
    value isa AbstractString || error("$(name) must be a string")
    occursin(r"^[0-9a-f]{64}$", value) || error("$(name) must be 64 lowercase hexadecimal characters")
    return value
end

function _validate_relative_manifest(value)
    value isa String || error("artifact_manifest must be a string")
    isempty(value) && error("artifact_manifest must not be empty")
    isabspath(value) && error("artifact_manifest must be relative")
    occursin('\\', value) && error("artifact_manifest must use slash-separated spelling")
    normpath(value) == value || error("artifact_manifest spelling must be normalized")
    parts = split(value, '/')
    all(part -> !isempty(part) && part != "." && part != "..", parts) ||
        error("artifact_manifest must not traverse directories")
    return value
end

function _validate_status(record; expected_state::Union{Nothing,String}=nothing)
    record isa AbstractDict || error("status record must be a TOML table")
    haskey(record, "state") || error("status record is missing state")
    state = record["state"]
    state isa String || error("status state must be a string")
    state in (INCOMPLETE_STATE, COMPLETE_STATE) || error("invalid status state: $(state)")
    expected_state === nothing || state == expected_state ||
        error("expected $(expected_state) status, found $(state)")

    expected_keys = state == INCOMPLETE_STATE ?
                    Set(("schema_version", "state", "phase", "fingerprint")) :
                    Set((
                        "schema_version",
                        "state",
                        "phase",
                        "fingerprint",
                        "artifact_manifest",
                        "artifact_manifest_sha256",
                        "provenance_sha256",
                    ))
    Set(keys(record)) == expected_keys || error("status record has an invalid field set")

    schema_version = record["schema_version"]
    schema_version isa Integer && !(schema_version isa Bool) && schema_version == SCHEMA_VERSION ||
        error("status schema_version must be integer $(SCHEMA_VERSION)")
    phase = record["phase"]
    phase isa String || error("status phase must be a string")
    phase in VALID_PHASES || error("invalid status phase: $(phase)")
    _validate_sha256(record["fingerprint"], "fingerprint")

    if state == COMPLETE_STATE
        _validate_relative_manifest(record["artifact_manifest"])
        _validate_sha256(record["artifact_manifest_sha256"], "artifact_manifest_sha256")
        _validate_sha256(record["provenance_sha256"], "provenance_sha256")
    end
    return record
end

function _require_run_directory(path::String)
    islink(path) && error("run output directory must not be a symlink: $(path)")
    isdir(path) || error("run output is not a directory: $(path)")
    return path
end

function _safe_run_file(path::String, relative::AbstractString)
    _require_run_directory(path)
    current = path
    for part in split(relative, '/')
        current = joinpath(current, part)
        islink(current) && error("run file must not be a symlink: $(current)")
    end
    isfile(current) || error("required run file is missing: $(current)")
    return current
end

function _status_file(path::String)
    return _safe_run_file(path, "status.toml")
end

function _load_status(path::String)
    status_path = _status_file(path)
    try
        return TOML.parsefile(status_path)
    catch err
        error("invalid status TOML at $(status_path): $(sprint(showerror, err))")
    end
end

function _sha256_file(path::String)
    return bytes2hex(SHA.sha256(read(path)))
end

function _portable_artifact_parts(relative::AbstractString)
    isempty(relative) && error("artifact manifest path is empty")
    isabspath(relative) && error("artifact manifest path is absolute")
    occursin(r"^[A-Za-z]:", relative) &&
        error("artifact manifest path has a drive prefix")
    occursin('\\', relative) &&
        error("artifact manifest path uses a non-portable separator")
    any(iscntrl, relative) && error("artifact manifest path contains a control character")
    parts = split(relative, '/'; keepempty=true)
    all(part -> !isempty(part) && part != "." && part != "..", parts) ||
        error("artifact manifest path is not canonical: $(relative)")
    join(parts, '/') == relative ||
        error("artifact manifest path is not canonical: $(relative)")
    return parts
end

function _artifact_fingerprint(path::String, relative::AbstractString)
    parts = _portable_artifact_parts(relative)
    current = path
    for part in parts
        current = joinpath(current, part)
        islink(current) && error("artifact manifest entry must not be a symlink: $(relative)")
    end
    isfile(current) || error("artifact manifest entry is missing: $(relative)")

    return open(current, "r") do io
        opened_before = stat(io)
        named_before = stat(current)
        opened_before.device == named_before.device &&
            opened_before.inode == named_before.inode ||
            error("artifact manifest entry changed while opening: $(relative)")
        digest = bytes2hex(SHA.sha256(io))
        opened_after = stat(io)
        named_after = stat(current)
        for field in (:device, :inode, :mode, :size, :mtime, :ctime)
            getproperty(opened_before, field) == getproperty(opened_after, field) &&
                getproperty(named_before, field) == getproperty(named_after, field) ||
                error("artifact manifest entry changed while hashing: $(relative)")
        end
        opened_after.device == named_after.device &&
            opened_after.inode == named_after.inode ||
            error("artifact manifest entry path changed while hashing: $(relative)")
        _safe_run_file(path, relative) == current ||
            error("artifact manifest entry path changed: $(relative)")
        return (bytes=Int(opened_after.size), sha256=digest)
    end
end

function _validate_artifact_manifest(path::String, manifest_path::String)
    content = try
        read(manifest_path, String)
    catch err
        error("invalid artifact manifest encoding: $(sprint(showerror, err))")
    end
    endswith(content, '\n') || error("artifact manifest must end with a newline")
    lines = split(content, '\n'; keepempty=true)
    isempty(last(lines)) || error("invalid artifact manifest line ending")
    pop!(lines)
    length(lines) >= 2 || error("artifact manifest contains no artifact rows")
    first(lines) == "path\tbytes\tsha256" || error("invalid artifact manifest header")

    previous = nothing
    seen = Set{String}()
    for line in Iterators.drop(lines, 1)
        fields = split(line, '\t'; keepempty=true)
        length(fields) == 3 || error("invalid artifact manifest row field count")
        relative, bytes_text, expected_sha = fields
        _portable_artifact_parts(relative)
        relative in seen && error("duplicate artifact manifest path: $(relative)")
        previous === nothing || previous < relative ||
            error("artifact manifest paths are not strictly sorted")
        push!(seen, relative)
        previous = relative
        occursin(r"^(0|[1-9][0-9]*)$", bytes_text) ||
            error("invalid artifact manifest byte count: $(bytes_text)")
        expected_bytes = try
            parse(Int, bytes_text)
        catch
            error("invalid artifact manifest byte count: $(bytes_text)")
        end
        _validate_sha256(expected_sha, "artifact manifest SHA-256")
        actual = _artifact_fingerprint(path, relative)
        actual.bytes == expected_bytes ||
            error("artifact hash mismatch: $(relative) (size mismatch)")
        actual.sha256 == expected_sha || error("artifact hash mismatch: $(relative)")
    end
    return nothing
end

function _toml_bytes(record::Dict{String,Any})
    io = IOBuffer()
    TOML.print(io, record; sorted=true)
    return take!(io)
end

function _incomplete_record(config::Dict, phase::String, expected::String)
    return Dict{String,Any}(
        "schema_version" => SCHEMA_VERSION,
        "state" => INCOMPLETE_STATE,
        "phase" => phase,
        "fingerprint" => expected,
    )
end

function _rename_noreplace(source::String, target::String)
    _require_linux("atomic no-overwrite run publication")
    result = ccall(
        :renameat2,
        Cint,
        (Cint, Cstring, Cint, Cstring, Cuint),
        AT_FDCWD,
        source,
        AT_FDCWD,
        target,
        RENAME_NOREPLACE,
    )
    result == 0 && return nothing
    error("atomic run publication failed for $(target): $(Base.Libc.strerror(Base.Libc.errno()))")
end

function _staging_namespace(path::String)
    namespace = joinpath(dirname(path), "$(STAGING_PREFIX)$(basename(path))")
    islink(namespace) && error("run staging namespace must not be a symlink: $(namespace)")
    mkpath(namespace)
    isdir(namespace) || error("run staging namespace is not a directory: $(namespace)")
    return namespace
end

function _publish_incomplete(path::String, record::Dict{String,Any})
    parent = dirname(path)
    mkpath(parent)
    namespace = _staging_namespace(path)
    staging = mktempdir(namespace; prefix="run-")
    try
        status_path = joinpath(staging, "status.toml")
        open(status_path, "w") do io
            write(io, _toml_bytes(record))
            flush(io)
        end
        _validate_status(TOML.parsefile(status_path); expected_state=INCOMPLETE_STATE)
        _rename_noreplace(staging, path)
    finally
        ispath(staging) && rm(staging; recursive=true, force=true)
    end
    return nothing
end

function reserve_run!(lease::RunLease, config::Dict; resume::Bool=false)
    path = _lease_path(lease)
    phase = _config_phase(config)
    expected = fingerprint(config)

    if !ispath(path) && !islink(path)
        _publish_incomplete(path, _incomplete_record(config, phase, expected))
        return :new
    end

    _require_run_directory(path)
    resume || error("run output already exists: $(path)")
    status = _validate_status(_load_status(path); expected_state=INCOMPLETE_STATE)
    status["phase"] == phase || error("resume phase mismatch")
    status["fingerprint"] == expected || error("resume fingerprint mismatch")
    return :resume
end

function _atomic_replace_status(path::String, record::Dict{String,Any})
    status_path = _status_file(path)
    namespace = _staging_namespace(path)
    temp_path, io = mktemp(namespace)
    try
        write(io, _toml_bytes(record))
        flush(io)
        close(io)
        result = ccall(:rename, Cint, (Cstring, Cstring), temp_path, status_path)
        result == 0 || error(
            "atomic status replacement failed for $(status_path): " *
            Base.Libc.strerror(Base.Libc.errno()),
        )
    finally
        isopen(io) && close(io)
        ispath(temp_path) && rm(temp_path; force=true)
    end
    return nothing
end

function mark_complete!(lease::RunLease, config::Dict; artifact_manifest::String)
    path = _lease_path(lease)
    phase = _config_phase(config)
    expected = fingerprint(config)
    _require_run_directory(path)
    status = _validate_status(_load_status(path); expected_state=INCOMPLETE_STATE)
    status["phase"] == phase || error("completion phase mismatch")
    status["fingerprint"] == expected || error("completion fingerprint mismatch")

    manifest_spelling = _validate_relative_manifest(artifact_manifest)
    manifest_path = _safe_run_file(path, manifest_spelling)
    provenance_path = _safe_run_file(path, "provenance.toml")
    manifest_sha256 = _sha256_file(manifest_path)
    provenance_sha256 = _sha256_file(provenance_path)
    _validate_artifact_manifest(path, manifest_path)
    _sha256_file(manifest_path) == manifest_sha256 ||
        error("artifact manifest changed during completion")
    _sha256_file(provenance_path) == provenance_sha256 ||
        error("provenance changed during completion")
    record = Dict{String,Any}(
        "schema_version" => SCHEMA_VERSION,
        "state" => COMPLETE_STATE,
        "phase" => phase,
        "fingerprint" => expected,
        "artifact_manifest" => manifest_spelling,
        "artifact_manifest_sha256" => manifest_sha256,
        "provenance_sha256" => provenance_sha256,
    )
    _validate_status(record; expected_state=COMPLETE_STATE)
    _atomic_replace_status(path, record)
    return nothing
end

function assert_complete!(path::String; phase::String)
    phase in VALID_PHASES || error("invalid expected phase: $(phase)")
    target = normpath(abspath(path))
    _require_run_directory(target)
    status = _validate_status(_load_status(target); expected_state=COMPLETE_STATE)
    status["phase"] == phase || error("complete run phase mismatch")

    manifest_path = _safe_run_file(target, status["artifact_manifest"])
    provenance_path = _safe_run_file(target, "provenance.toml")
    _sha256_file(manifest_path) == status["artifact_manifest_sha256"] ||
        error("artifact manifest hash mismatch")
    _sha256_file(provenance_path) == status["provenance_sha256"] ||
        error("provenance hash mismatch")
    _validate_artifact_manifest(target, manifest_path)
    _sha256_file(manifest_path) == status["artifact_manifest_sha256"] ||
        error("artifact manifest changed during validation")
    _sha256_file(provenance_path) == status["provenance_sha256"] ||
        error("provenance changed during validation")
    return status
end

end
