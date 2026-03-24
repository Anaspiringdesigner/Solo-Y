using Oxygen
using HTTP
using Flux
using OneHotArrays
using JSON3

Oxygen.resetstate() # Clears old routes before starting

println("Loading the Lstm Brain in to the server...")

# 1. rebuild the brain exactly as we had it

model = Chain(
    LSTM(2 => 64),
    Dense(64 => 6),
    softmax
)

optim = Flux.setup(Adam(0.01), model)

baseline_hr = 70.0
baseline_hrv = 45.0

# --- THE API ROUTES ---

# Route 1: Health check (To make sure the app can talk to the server)
@get "/" function(req::HTTP.Request)
    return Dict("status" => "Online", "message" => "ADHD Bio-Brain is listening")
end

# Route 2: The heavily armored prediction Engine
@post "/predict" function(req::HTTP.Request)
    try
        println("\n--- NEW PREDICTION REQUEST ---")
        println("Raw body: ", String(req.body))

        # Safely parse the JSON using JSON3 directly
        data = JSON3.read(req.body)
        
        # Safely extract the sequence (handles both Dict and JSON3 Object formats)
        sequence = haskey(data, :sequence) ? data[:sequence] : data["sequence"]
        println("Extracted sequence of length: ", length(sequence))

        # Always reset the LSTM's short-term memory before a new sequence
        Flux.reset!(model)

        local final_prediction

        # Feed the sequence in order to build context
        for reading in sequence
            hr_delta = Float32((reading[1] - baseline_hr) / baseline_hr)
            hrv_delta = Float32((reading[2] - baseline_hrv) / baseline_hrv)

            # Reshape for LSTM
            features = reshape(Float32[hr_delta, hrv_delta], 2, 1)

            # The model processes it
            final_prediction = model(features)
        end

        predicted_class = argmax(final_prediction)[1]
        confidence = maximum(final_prediction) * 100

        println("Success! Predicted Class: ", predicted_class)

        return Dict(
            "prediction_class" => predicted_class,
            "confidence_percent" => round(confidence, digits=2),
            "full_distribution" => round.(final_prediction, digits=3)
        )

    catch e
        # THIS IS THE ALARM SYSTEM
        println("\n!!! SERVER CRASHED !!!")
        showerror(stdout, e, catch_backtrace())
        println("\n----------------------")
        
        # This forces the server to return the exact error to your phone screen too
        return HTTP.Response(500, "FATAL ERROR: $(string(e))")
    end
end

# Route 3: The Active Learning Engine (When you tap a button on the app)
@post "/learn" function(req::HTTP.Request)
    data = json(req)
    sequence = data.sequence
    true_label = data.label

    Flux.reset!(model)

    # Format the sequence just like we did above
    formatted_sequence = [reshape(Float32[((r[1] - baseline_hr) / baseline_hr), ((r[2] - baseline_hrv) / baseline_hrv)], 2, 1) for r in sequence]

    y_true = reshape(onehot(true_label, 1:6), 6, 1)

    loss, gradients = Flux.withgradient(model) do m
        predictions = [m(x) for x in formatted_sequence]

        # Calculate error based on the final prediction of the sequence
        Flux.crossentropy(predictions[end], y_true)
        
    end

    Flux.update!(optim, model, gradients[1])

    return Dict(
        "status" => "Success",
        "message" => "Brain updated! Learned Class $true_label.",
        "new_error_rate" => round(loss, digits = 4)
    )
end

# ------START THE SERVER ---
# ------ Listens on all local IP addresses at port 8080
println("Starting server on port 8080...")
serve(host="0.0.0.0", port=8080)