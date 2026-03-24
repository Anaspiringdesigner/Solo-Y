using Flux
using OneHotArrays

println("Initializing the Sequence-Aware Brain (LSTM) with Probabilities...")

# 1. Define the Recurrent Model
model = Chain(
    LSTM(2 => 64),      # The memory layer. Takes 2 inputs, outputs 16 internal states.
    Dense(64 => 6),     # The output layer. Translates the 16 states into 6 classes.
    softmax             # NEW: Squeezes the output into a probability distribution (0.0 to 1.0)
)

optim = Flux.setup(Adam(0.01), model)

baseline_hr = 70.0
baseline_hrv = 45.0

# 2. Simulate an entire 24-hour day
function simulate_full_day()
    day_length = 96
    
    features_sequence = Vector{Matrix{Float32}}()
    labels_sequence = Vector{Int}()
    
    for i in 1:day_length
        raw_hr = rand(40:220) 
        raw_hrv = rand(15:75) 

        hr_delta = Float32((raw_hr - baseline_hr) / baseline_hr)
        hrv_delta = Float32((raw_hrv - baseline_hrv) / baseline_hrv)

        label = if hrv_delta > 0.30
            6
        elseif hr_delta > 0.15 && hrv_delta < -0.20
            2
        elseif hr_delta > 0.05 && hr_delta <= 0.15 && hrv_delta <= -0.15
            5
        elseif hr_delta > 0.02 && hr_delta <= 0.10 && hrv_delta >= -0.10
            3
        elseif hr_delta <= 0.02 && hrv_delta > 0.05
            4
        else
            1
        end
        
        push!(features_sequence, reshape(Float32[hr_delta, hrv_delta], 2, 1))
        push!(labels_sequence, label)
    end
    
    return features_sequence, labels_sequence
end

# 3. The Sequence Learning Function
function train_full_day!(model, optim, day_features, day_labels)
    Flux.reset!(model) 
    
    y_true = [reshape(onehot(l, 1:6), 6, 1) for l in day_labels]
    
    loss, gradients = Flux.withgradient(model) do m
        predictions = [m(x) for x in day_features]
        
        # NEW: Changed to `crossentropy` because `softmax` is already handling the probabilities
        total_loss = sum(Flux.crossentropy(pred, truth) for (pred, truth) in zip(predictions, y_true))
        
        return total_loss / length(day_features)
    end
    
    Flux.update!(optim, model, gradients[1])
    return loss
end

# --- RUNNING THE TEST ---
println("Running a simulation of 3 full days...")
println("----------------------------------------------------------")

for day in 1:3
    day_features, day_labels = simulate_full_day()
    
    println("Processing Day $day (96 data points)...")
    
    error_loss = train_full_day!(model, optim, day_features, day_labels)
    
    println("Day $day completed! Average Error rate: $(round(error_loss, digits = 4))\n")
end

# Let's do a quick test prediction to see the probabilities!
Flux.reset!(model) # Clear memory before a fresh guess
test_feature = reshape(Float32[0.20, -0.25], 2, 1) # Simulating high HR, low HRV (Panic/Procrastination)
probs = model(test_feature)
println("Sample Probability Output for a single reading:")
println(round.(probs, digits=3))