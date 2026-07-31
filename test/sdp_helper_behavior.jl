using Test
using DataFrames
using Dates
using EMSx
using StoOpt

include(joinpath(@__DIR__, "..", "EMSx.jl", "examples", "sdp", "function.jl"))

function synthetic_law()
    timestamps = collect(Time(0):Minute(15):Time(23, 45))
    frame = DataFrame(
        timestamp=timestamps,
        value=[[Float64(index), Float64(index + 100)] for index in 1:96],
        probability=[[0.2, 0.2] for _ in 1:96],
    )
    return Dict("week_day" => frame, "week_end" => deepcopy(frame))
end

@testset "pre-existing SDP helper behavior" begin
    noises = data_frames_to_noises(synthetic_law())
    @test length(noises) == 672
    for time_index in 1:672
        variable = StoOpt.RandomVariable(noises, time_index)
        @test length(variable.value) == 2
        @test isapprox(sum(variable.probability), 1.0; atol=eps(Float64), rtol=0)
    end
end
