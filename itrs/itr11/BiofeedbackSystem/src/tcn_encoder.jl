# ============================================================
# tcn_encoder.jl
# Julia/Flux port of brain_tcn.py
# TCN Encoder: 4 dilated residual blocks → latent z ∈ ℝ³²
# ============================================================

module TCNEncoder

using Flux
using Flux: Chain, Conv, BatchNorm, Dense, relu
using Statistics
using BSON: @save, @load
using NPZ
using Random

# ── Config ───────────────────────────────────────────────────
const WINDOW_SECONDS = 30
const INPUT_DIM      = 3
const LATENT_DIM     = 32
const TCN_FILTERS    = 32
const TCN_KERNEL     = 3
const DILATIONS      = (1, 2, 4, 8)
const DROPOUT_RATE   = 0.1f0

const MODEL_DIR    = "models"
const ENCODER_PATH = joinpath(MODEL_DIR, "tcn_encoder.bson")
const SCALER_PATH  = joinpath(MODEL_DIR, "scaler.npz")

const DEFAULT_MEDIAN = Float32[70.0, 30.0, 14.0]
const DEFAULT_IQR    = Float32[15.0, 20.0,  6.0]

# ── Scaler ───────────────────────────────────────────────────
struct RobustScaler
    median :: Vector{Float32}
    iqr    :: Vector{Float32}
end

function default_scaler()
    RobustScaler(copy(DEFAULT_MEDIAN), copy(DEFAULT_IQR))
end

function load_scaler(path::String)::RobustScaler
    if !isfile(path)
        println("[SCALER] Not found at $path, using default")
        return default_scaler()
    end
    data = npzread(path)
    med  = Float32.(data["median"])
    iqr  = Float32.(data["iqr"])
    iqr  = [abs(v) < 1f-6 ? 1f0 : v for v in iqr]
    println("[SCALER] Loaded from $path")
    return RobustScaler(med, iqr)
end

function scale_window(seq::Array{Float32,2},
                      scaler::RobustScaler)::Array{Float32,2}
    out = copy(seq)
    for ch in 1:size(out, 2)
        out[:, ch] = (out[:, ch] .- scaler.median[ch]) ./
                      scaler.iqr[ch]
    end
    return out
end

# ── TCN Residual Block ────────────────────────────────────────
struct TCNResBlock
    conv1     :: Conv
    bn1       :: BatchNorm
    conv2     :: Conv
    bn2       :: BatchNorm
    proj      :: Union{Conv, Nothing}
    drop_rate :: Float32
end

Flux.@layer TCNResBlock

function TCNResBlock(in_ch::Int, filters::Int,
                     kernel::Int, dilation::Int,
                     drop_rate::Float32)
    pad   = (kernel - 1) * dilation
    conv1 = Conv((kernel,), in_ch  => filters;
                 pad=(pad, 0), dilation=dilation)
    bn1   = BatchNorm(filters)
    conv2 = Conv((kernel,), filters => filters;
                 pad=(pad, 0), dilation=dilation)
    bn2   = BatchNorm(filters)
    proj  = in_ch != filters ?
            Conv((1,), in_ch => filters; pad=0) :
            nothing
    return TCNResBlock(conv1, bn1, conv2, bn2, proj, drop_rate)
end

function (block::TCNResBlock)(x::AbstractArray;
                               training::Bool=false)
    shortcut = x
    y = block.conv1(x)
    y = block.bn1(y)
    y = relu.(y)
    y = training ? Flux.dropout(y, block.drop_rate) : y
    y = block.conv2(y)
    y = block.bn2(y)
    y = relu.(y)
    y = training ? Flux.dropout(y, block.drop_rate) : y
    if block.proj !== nothing
        shortcut = block.proj(shortcut)
    end
    return relu.(y .+ shortcut)
end

# ── TCN Encoder Model ─────────────────────────────────────────
struct TCNEncoderModel
    blocks :: Vector{TCNResBlock}
    dense  :: Dense
    ln     :: LayerNorm
end

Flux.@layer TCNEncoderModel

function build_tcn_encoder()::TCNEncoderModel
    blocks = TCNResBlock[]
    in_ch  = INPUT_DIM
    for d in DILATIONS
        push!(blocks, TCNResBlock(in_ch, TCN_FILTERS,
                                  TCN_KERNEL, d, DROPOUT_RATE))
        in_ch = TCN_FILTERS
    end
    dense = Dense(TCN_FILTERS => LATENT_DIM)
    ln    = LayerNorm(LATENT_DIM)
    return TCNEncoderModel(blocks, dense, ln)
end

function (enc::TCNEncoderModel)(x::AbstractArray;
                                 training::Bool=false)
    # x: (batch, time, channels) → permute → (time, channels, batch)
    h = permutedims(x, (2, 3, 1))
    for block in enc.blocks
        h = block(h; training=training)
    end
    # GlobalAveragePooling over time dim
    h = mean(h, dims=1)
    h = dropdims(h, dims=1)      # (channels, batch)
    z = enc.dense(h)
    z = enc.ln(z)
    return z
end

# ── Autoencoder ───────────────────────────────────────────────
struct TCNAutoencoder
    encoder :: TCNEncoderModel
    decoder :: Chain
end

Flux.@layer TCNAutoencoder

function build_autoencoder(encoder::TCNEncoderModel)::TCNAutoencoder
    decoder = Chain(
        Dense(LATENT_DIM => WINDOW_SECONDS * 64, relu),
        x -> reshape(x, WINDOW_SECONDS, 64, :),
        Conv((3,), 64 => 64, relu; pad=1),
        Conv((3,), 64 => 32, relu; pad=1),
        Conv((1,), 32 => INPUT_DIM; pad=0),
    )
    return TCNAutoencoder(encoder, decoder)
end

function (ae::TCNAutoencoder)(x::AbstractArray;
                               training::Bool=false)
    z     = ae.encoder(x; training=training)
    recon = ae.decoder(z)
    return permutedims(recon, (3, 1, 2))
end

# ── Save / Load ───────────────────────────────────────────────
function save_encoder(enc::TCNEncoderModel,
                      path::String=ENCODER_PATH)
    mkpath(dirname(path))
    @save path enc
    println("[SAVE] Encoder saved to $path")
end

function load_encoder(path::String=ENCODER_PATH)::TCNEncoderModel
    if !isfile(path)
        println("[LOAD] No saved encoder, building fresh")
        return build_tcn_encoder()
    end
    @load path enc
    println("[LOAD] Encoder loaded from $path")
    return enc
end

# ── App State ─────────────────────────────────────────────────
mutable struct EncoderState
    encoder          :: Union{TCNEncoderModel, Nothing}
    scaler           :: RobustScaler
    latest           :: Union{Dict, Nothing}
    buffer           :: Vector{Dict}
    using_pretrained :: Bool
end

function EncoderState()
    EncoderState(nothing, default_scaler(), nothing, Dict[], false)
end

const STATE = EncoderState()
const BUFFER_MAXSIZE = 1000

# ── Encode Window ─────────────────────────────────────────────
function encode_window(hr      :: Vector{Float32},
                        hrv     :: Vector{Float32},
                        br      :: Vector{Float32},
                        avg_hr  :: Float32,
                        avg_hrv :: Float32,
                        avg_br  :: Float32,
                        end_time:: String)::Union{Dict, Nothing}

    STATE.encoder === nothing && return nothing

    try
        function fix_len(arr, n)
            length(arr) >= n ? arr[1:n] :
            vcat(arr, fill(arr[end], n - length(arr)))
        end

        hr_f  = fix_len(hr,  WINDOW_SECONDS)
        hrv_f = fix_len(hrv, WINDOW_SECONDS)
        br_f  = fix_len(br,  WINDOW_SECONDS)

        seq        = hcat(hr_f, hrv_f, br_f)
        seq_scaled = scale_window(seq, STATE.scaler)

        x = reshape(seq_scaled, 1, WINDOW_SECONDS, INPUT_DIM)
        z = STATE.encoder(x; training=false)
        z_vec = vec(z)

        item = Dict(
            "end_time" => end_time,
            "avg_hr"   => Float64(avg_hr),
            "avg_hrv"  => Float64(avg_hrv),
            "avg_br"   => Float64(avg_br),
            "z"        => Float64.(z_vec),
        )

        STATE.latest = item
        push!(STATE.buffer, item)
        if length(STATE.buffer) > BUFFER_MAXSIZE
            popfirst!(STATE.buffer)
        end

        println("[ENCODE] end=$(end_time) " *
                "HR=$(round(avg_hr, digits=1)) " *
                "HRV=$(round(avg_hrv, digits=1))")
        return item

    catch e
        println("[ENCODE ERROR] $e")
        return nothing
    end
end

# ── Init ──────────────────────────────────────────────────────
function init_encoder()
    mkpath(MODEL_DIR)
    STATE.scaler = load_scaler(SCALER_PATH)

    if isfile(ENCODER_PATH)
        println("[INIT] Loading pretrained encoder: $ENCODER_PATH")
        STATE.encoder        = load_encoder(ENCODER_PATH)
        STATE.using_pretrained = true
    else
        println("[INIT] No pretrained encoder, building fresh")
        STATE.encoder        = build_tcn_encoder()
        STATE.using_pretrained = false
    end

    println("[INIT] Encoder ready | latent_dim=$(LATENT_DIM)")
end

end # module TCNEncoder