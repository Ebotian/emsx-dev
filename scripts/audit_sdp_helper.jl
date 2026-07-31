using SHA
using TOML
using Dates

const ROOT = normpath(joinpath(@__DIR__, ".."))
const EMSX_ROOT = joinpath(ROOT, "EMSx.jl")
const PATH = "examples/sdp/function.jl"
const OUTPUT = joinpath(ROOT, "audit", "emsx-sdp-helper-preexisting.toml")

diff = read(`git -C $EMSX_ROOT diff --binary -- $PATH`, String)
isempty(diff) && error("expected pre-existing helper diff is absent")
for fragment in ("w = collect(w')", "pw = collect(pw')", "pw[:, t] ./= sum(pw[:, t])")
    occursin(fragment, diff) || error("missing audited fragment: $(fragment)")
end

record = Dict(
    "schema_version" => 1,
    "captured_at_utc" => string(Dates.now(Dates.UTC)),
    "nested_head" => readchomp(`git -C $EMSX_ROOT rev-parse HEAD`),
    "path" => PATH,
    "diff_sha256" => bytes2hex(SHA.sha256(codeunits(diff))),
)
mkpath(dirname(OUTPUT))
if isfile(OUTPUT)
    existing = TOML.parsefile(OUTPUT)
    for key in ("schema_version", "nested_head", "path", "diff_sha256")
        existing[key] == record[key] || error("existing helper audit mismatch: $(key)")
    end
else
    open(OUTPUT, "w") do io
        TOML.print(io, record; sorted=true)
    end
end
