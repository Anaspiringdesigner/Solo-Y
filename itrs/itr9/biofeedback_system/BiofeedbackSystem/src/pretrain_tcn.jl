# ============================================================
# pretrain_tcn.jl
# TCN Autoencoder Pretraining + Incremental Top-up
#
# Usage:
#   Initial training:  julia src/pretrain_tcn.jl
#   Top-up training:   julia src/pretrain_tcn.jl --topup
#   Force retrain:     julia src/pretrain_tcn.jl --force
# ============================================================

include("data_streamer.jl")
include("tcn_encoder.jl")

using .DataStreamer
using .TCNEncoder
using Flux
using Flux: withgradient
using Flux.Optimise: Adam, update!
using Statistics
using Random
using BSON: @save, @load
using Dates
using NPZ

# ── Config ───────────────────────────────────────────────────
const SEED          = 42
const BATCH_SIZE    = 64
const EPOCHS        = 120
const VAL_SPLIT     = 0.2
const PATIENCE      = 8          # early stopping
const TOPUP_EPOCHS  = 30         # fewer epochs for top-up
const TOPUP_LR      = 1f-4       # lower LR for top-up
const INITIAL_LR    = 1f-3       # higher LR for initial
const TOPUP_OLD_RATIO = 0.3      # 30% old data in top-up

# Paths
const FLAG_PATH      = joinpath(TCNEncoder.MODEL_DIR,
                                "trained_once.flag")
const TIMESTAMP_PATH = joinpath(TCNEncoder.MODEL_DIR,
                                "last_trained.bson")
const OLD_DATA_PATH  = joinpath(TCNEncoder.MODEL_DIR,
                                "old_data_sample.bson")

Random.seed!(SEED)

# ── ADB Data Loader ───────────────────────────────────────────
function load_windows_from_android(;
        only_after::Union{DateTime, Nothing}=nothing,
        label::String="all")

    if !DataStreamer.adb_is_connected()
        error("[PRETRAIN] ADB not connected")
    end

    files = DataStreamer.adb_list_hr_files(
                DataStreamer.ANDROID_POLAR_DIR)
    isempty(files) && error("[PRETRAIN] No HR files found")

    println("[PRETRAIN] Found $(length(files)) HR files")

    all_windows = Array{Float32, 3}[]
    seen        = Set{String}()

    for fname in files
        android_path = "$(DataStreamer.ANDROID_POLAR_DIR)/$(fname)"
        local_path   = joinpath(DataStreamer.LOCAL_TEMP, fname)

        ok = DataStreamer.adb_pull_file(android_path, local_path)
        (!ok || !isfile(local_path)) && continue

        h = DataStreamer.file_hash(local_path)
        h in seen && continue
        push!(seen, h)

        rows = DataStreamer.parse_polar_hr_file(local_path)
        isempty(rows) && continue

        # Filter by timestamp if top-up
        if only_after !== nothing
            rows = filter(r -> r.timestamp > only_after,
                          rows)
            isempty(rows) && continue
        end

        timestamps, hr, hrv, br =
            DataStreamer.resample_and_clean(rows)
        isempty(timestamps) && continue

        # Build non-overlapping windows
        n   = length(timestamps)
        W   = TCNEncoder.WINDOW_SECONDS
        wins = Array{Float32}[]

        for s in 1:W:(n - W + 1)
            e   = s + W - 1
            seq = hcat(hr[s:e], hrv[s:e], br[s:e])
            push!(wins, seq)
        end

        if !isempty(wins)
            X = zeros(Float32,
                      length(wins), W,
                      TCNEncoder.INPUT_DIM)
            for (i, w) in enumerate(wins)
                X[i, :, :] = w
            end
            push!(all_windows, X)
            println("[PRETRAIN] $(fname): " *
                    "$(length(wins)) windows")
        end
    end

    isempty(all_windows) &&
        error("[PRETRAIN] No windows found ($label)")

    X = cat(all_windows..., dims=1)
    println("[PRETRAIN] Total $label windows: " *
            "$(size(X, 1)) | shape=$(size(X))")
    return X
end

# ── Robust Scaler ─────────────────────────────────────────────
function fit_robust_scaler(X::Array{Float32, 3})
    flat = reshape(X, :, size(X, 3))
    med  = Float32.(median(flat, dims=1)[1, :])
    q1   = Float32.([quantile(flat[:, c], 0.25)
                     for c in 1:size(flat, 2)])
    q3   = Float32.([quantile(flat[:, c], 0.75)
                     for c in 1:size(flat, 2)])
    iqr  = q3 .- q1
    iqr  = [abs(v) < 1f-6 ? 1f0 : v for v in iqr]
    return RobustScaler(med, Float32.(iqr))
end

function transform_robust(X::Array{Float32, 3},
                           scaler::RobustScaler)
    Y = copy(X)
    for ch in 1:size(Y, 3)
        Y[:, :, ch] = (Y[:, :, ch] .- scaler.median[ch]) ./
                       scaler.iqr[ch]
    end
    return Y
end

# ── Autoencoder Forward Pass ──────────────────────────────────
function ae_forward(encoder::TCNEncoderModel,
                    decoder::Chain,
                    x::Array{Float32, 3})
    # x: (batch, time, channels)
    z    = encoder(x; training=true)      # (latent, batch)
    recon = decoder(z)                     # (time, channels, batch)
    # permute back to (batch, time, channels)
    return permutedims(recon, (3, 1, 2))
end

# ── Train One Epoch ───────────────────────────────────────────
function train_epoch!(encoder::TCNEncoderModel,
                      decoder::Chain,
                      opt_enc::Adam,
                      opt_dec::Adam,
                      X::Array{Float32, 3},
                      batch_size::Int)::Float32

    n      = size(X, 1)
    idx    = randperm(n)
    losses = Float32[]

    for i in 1:batch_size:(n - batch_size + 1)
        batch_idx = idx[i:min(i+batch_size-1, n)]
        xb        = X[batch_idx, :, :]

        loss, gs = withgradient(encoder, decoder) do enc, dec
            recon = ae_forward(enc, dec, xb)
            Flux.mse(recon, xb)
        end

        update!(opt_enc, encoder, gs[1])
        update!(opt_dec, decoder, gs[2])
        push!(losses, loss)
    end

    return mean(losses)
end

# ── Validation Loss ───────────────────────────────────────────
function val_loss(encoder::TCNEncoderModel,
                  decoder::Chain,
                  X_val::Array{Float32, 3})::Float32
    recon = ae_forward(encoder, decoder, X_val)
    return Flux.mse(recon, X_val)
end

# ── Train Loop with Early Stopping ────────────────────────────
function train_loop!(encoder::TCNEncoderModel,
                     decoder::Chain,
                     X_train::Array{Float32, 3},
                     X_val::Array{Float32, 3};
                     epochs::Int    = EPOCHS,
                     lr::Float32    = INITIAL_LR,
                     patience::Int  = PATIENCE,
                     label::String  = "Training")

    opt_enc = Adam(lr)
    opt_dec = Adam(lr)

    best_val    = Inf32
    best_enc    = deepcopy(encoder)
    best_dec    = deepcopy(decoder)
    wait        = 0

    println("\n[$label] Starting | " *
            "train=$(size(X_train,1)) " *
            "val=$(size(X_val,1)) " *
            "epochs=$epochs lr=$lr")

    for epoch in 1:epochs
        train_l = train_epoch!(
            encoder, decoder,
            opt_enc, opt_dec,
            X_train, BATCH_SIZE)

        val_l = val_loss(encoder, decoder, X_val)

        println("  Epoch $epoch/$epochs | " *
                "train=$(round(train_l, digits=6)) | " *
                "val=$(round(val_l, digits=6))" *
                (val_l < best_val ? " ← best" : ""))

        if val_l < best_val
            best_val = val_l
            best_enc = deepcopy(encoder)
            best_dec = deepcopy(decoder)
            wait     = 0
        else
            wait += 1
            if wait >= patience
                println("  Early stopping at epoch $epoch")
                break
            end
        end
    end

    # Restore best weights
    Flux.loadmodel!(encoder, Flux.state(best_enc))
    Flux.loadmodel!(decoder, Flux.state(best_dec))

    println("[$label] Done | best_val=" *
            "$(round(best_val, digits=6))")
    return best_val
end

# ── Train/Val Split ───────────────────────────────────────────
function train_val_split(X::Array{Float32, 3},
                          val_ratio::Float32=0.2f0)
    n       = size(X, 1)
    idx     = randperm(n)
    n_val   = round(Int, n * val_ratio)
    val_idx = idx[1:n_val]
    trn_idx = idx[n_val+1:end]
    return X[trn_idx, :, :], X[val_idx, :, :]
end

# ── Save Training State ───────────────────────────────────────
function save_training_state(timestamp::DateTime,
                              old_sample::Array{Float32,3})
    mkpath(TCNEncoder.MODEL_DIR)

    # Save timestamp
    ts_str = string(timestamp)
    @save TIMESTAMP_PATH ts_str

    # Save sample of old data for top-up mixing
    @save OLD_DATA_PATH old_sample

    # Write flag
    open(FLAG_PATH, "w") do f
        write(f, "trained_once=true\n")
        write(f, "timestamp=$(timestamp)\n")
    end
    println("[PRETRAIN] State saved | timestamp=$timestamp")
end

# ── Load Training State ───────────────────────────────────────
function load_training_state()
    !isfile(TIMESTAMP_PATH) && return nothing, nothing

    @load TIMESTAMP_PATH ts_str
    timestamp = DateTime(ts_str)

    old_sample = nothing
    if isfile(OLD_DATA_PATH)
        @load OLD_DATA_PATH old_sample
    end

    return timestamp, old_sample
end

# ── PHASE 1: Initial Training ─────────────────────────────────
function initial_training()
    println("=" ^ 60)
    println("PHASE 1 — Initial Training")
    println("=" ^ 60)

    # Load all data
    println("\n[STEP 1] Loading all historical data...")
    X_raw = load_windows_from_android(label="historical")

    # Fit scaler
    println("\n[STEP 2] Fitting robust scaler...")
    scaler = fit_robust_scaler(X_raw)
    println("  median=$(round.(scaler.median, digits=2))")
    println("  iqr=$(round.(scaler.iqr, digits=2))")

    # Scale
    X = transform_robust(X_raw, scaler)

    # Train/val split
    X_train, X_val = train_val_split(X, Float32(VAL_SPLIT))

    # Build models
    println("\n[STEP 3] Building TCN autoencoder...")
    encoder = TCNEncoder.build_tcn_encoder()
    ae      = TCNEncoder.build_autoencoder(encoder)
    decoder = ae.decoder

    # Train
    println("\n[STEP 4] Training...")
    train_loop!(
        encoder, decoder,
        X_train, X_val;
        epochs  = EPOCHS,
        lr      = INITIAL_LR,
        patience = PATIENCE,
        label   = "Initial"
    )

    # Save encoder + scaler
    println("\n[STEP 5] Saving encoder + scaler...")
    TCNEncoder.save_encoder(encoder)
    npzwrite(TCNEncoder.SCALER_PATH,
             Dict("median" => scaler.median,
                  "iqr"    => scaler.iqr))
    println("  Scaler saved to $(TCNEncoder.SCALER_PATH)")

    # Save old data sample for future top-ups
    # Keep max 500 random windows as "memory"
    n_keep     = min(500, size(X_raw, 1))
    keep_idx   = randperm(size(X_raw, 1))[1:n_keep]
    old_sample = X_raw[keep_idx, :, :]

    save_training_state(now(), old_sample)

    println("\n[DONE] Initial training complete!")
    println("  Encoder: $(TCNEncoder.ENCODER_PATH)")
    println("  Scaler:  $(TCNEncoder.SCALER_PATH)")
end

# ── PHASE 2: Top-up Training ──────────────────────────────────
function topup_training()
    println("=" ^ 60)
    println("PHASE 2 — Top-up Training")
    println("=" ^ 60)

    # Load training state
    last_trained, old_sample = load_training_state()
    if last_trained === nothing
        println("[TOPUP] No previous training found!")
        println("[TOPUP] Running initial training instead...")
        initial_training()
        return
    end

    println("[TOPUP] Last trained: $last_trained")

    # Load NEW data only
    println("\n[STEP 1] Loading new data since $last_trained...")
    X_new_raw = try
        load_windows_from_android(
            only_after=last_trained,
            label="new")
    catch e
        println("[TOPUP] No new data found: $e")
        println("[TOPUP] Nothing to top-up")
        return
    end

    if size(X_new_raw, 1) < 10
        println("[TOPUP] Too few new windows " *
                "($(size(X_new_raw,1))) — skipping")
        return
    end

    # Load existing scaler
    println("\n[STEP 2] Loading existing scaler...")
    scaler = TCNEncoder.load_scaler(TCNEncoder.SCALER_PATH)

    # Scale new data
    X_new = transform_robust(X_new_raw, scaler)

    # Mix with old data (30% old, 70% new)
    X_combined = if old_sample !== nothing
        X_old_scaled = transform_robust(old_sample, scaler)
        n_old = round(Int,
                      size(X_new, 1) * TOPUP_OLD_RATIO)
        n_old = min(n_old, size(X_old_scaled, 1))

        if n_old > 0
            old_idx = randperm(
                size(X_old_scaled, 1))[1:n_old]
            old_mix = X_old_scaled[old_idx, :, :]
            println("[TOPUP] Mixing: " *
                    "$(size(X_new,1)) new + " *
                    "$(n_old) old windows")
            cat(X_new, old_mix, dims=1)
        else
            X_new
        end
    else
        X_new
    end

    # Shuffle combined data
    shuffle_idx = randperm(size(X_combined, 1))
    X_combined  = X_combined[shuffle_idx, :, :]

    # Train/val split
    X_train, X_val = train_val_split(
        X_combined, Float32(VAL_SPLIT))

    # Load existing encoder
    println("\n[STEP 3] Loading existing encoder...")
    encoder = TCNEncoder.load_encoder()
    ae      = TCNEncoder.build_autoencoder(encoder)
    decoder = ae.decoder

    # Fine-tune with lower LR
    println("\n[STEP 4] Fine-tuning...")
    train_loop!(
        encoder, decoder,
        X_train, X_val;
        epochs   = TOPUP_EPOCHS,
        lr       = TOPUP_LR,
        patience = PATIENCE,
        label    = "Top-up"
    )

    # Save updated encoder
    println("\n[STEP 5] Saving updated encoder...")
    TCNEncoder.save_encoder(encoder)

    # Update old data sample
    n_keep     = min(500, size(X_new_raw, 1))
    keep_idx   = randperm(size(X_new_raw, 1))[1:n_keep]
    new_sample = X_new_raw[keep_idx, :, :]

    # Merge with existing old sample
    updated_sample = if old_sample !== nothing
        n_keep_old = min(300, size(old_sample, 1))
        old_keep   = old_sample[
            randperm(size(old_sample,1))[1:n_keep_old],
            :, :]
        cat(new_sample, old_keep, dims=1)
    else
        new_sample
    end

    save_training_state(now(), updated_sample)

    println("\n[DONE] Top-up training complete!")
    println("  New windows used: $(size(X_new_raw, 1))")
    println("  Updated: $(TCNEncoder.ENCODER_PATH)")
end

# ── Entry Point ───────────────────────────────────────────────
function main()
    args    = ARGS
    force   = "--force"  in args
    is_topup = "--topup" in args

    println("=" ^ 60)
    println("TCN Pretraining")
    println("Args: $(args)")
    println("=" ^ 60)

    # Check ADB
    if !DataStreamer.adb_is_connected()
        println("[ERROR] ADB not connected!")
        println("  Connect your phone via USB")
        println("  Enable USB debugging")
        return
    end
    println("[OK] ADB connected")

    mkpath(TCNEncoder.MODEL_DIR)
    mkpath(DataStreamer.LOCAL_TEMP)

    if is_topup && !force
        # Top-up mode
        topup_training()
    elseif isfile(FLAG_PATH) && !force
        # Already trained — ask user
        println("\n[INFO] Already trained once.")
        println("  Use --topup for incremental training")
        println("  Use --force to retrain from scratch")
    else
        # Initial training
        initial_training()
    end
end

main()