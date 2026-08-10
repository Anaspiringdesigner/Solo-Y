module RLService

export choose_action

function choose_action(features::Dict{String, Float32})
    stress = get(features, "stress_score", 0f0)

    action = if stress > 0.75f0
        1
    elseif stress > 0.45f0
        2
    else
        3
    end

    return Dict(
        "action" => action,
        "score" => stress,
    )
end

end # module