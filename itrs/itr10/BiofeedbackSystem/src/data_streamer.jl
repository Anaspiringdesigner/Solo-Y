# ============================================================
# data_streamer.jl
# Live ADB reader — Julia port of polar_reader.py
# - Reads newest *_HR.txt from Android via ADB
# - Cleans, resamples, interpolates HR/HRV/BR
# - Builds 30s windows with 5s stride
# - POSTs only NEW + FRESH windows to /ingest
# ============================================================

module DataStreamer

using Dates
using Statistics
using SHA          # for MD5 file hash
using HTTP
using JSON3

# ── Config ──────────────────────────────────────────────────────────
const ANDROID_POLAR_DIR   = "/sdcard/Download/Data_from_H10"
const BRAIN_API           = "http://127.0.0.1:8000"

const POLL_INTERVAL       = 5          # seconds
const WINDOW_SECONDS      = 30
const STRIDE_SECONDS      = 5
const RECENT_MINUTES      = 20
const STALE_WINDOW_MINUTES = 3

const LOCAL_TEMP = joinpath(tempdir(), "polar_pulled_live")

# ── Valid ranges (same as Python) ───────────────────────────────────
const HR_MIN,  HR_MAX  = 30.0,  220.0
const HRV_MIN, HRV_MAX = 1.0,   250.0
const BR_MIN,  BR_MAX  = 4.0,   60.0

# ── Estimation clamp ranges ─────────────────────────────────────────
const HRV_EST_MIN, HRV_EST_MAX = 5.0,  120.0
const BR_EST_MIN,  BR_EST_MAX  = 8.0,  24.0

# ── Mutable state (replaces Python module-level dicts) ──────────────
mutable struct StreamerState
    file_states::Dict{String, String}           # fname → md5 hash
    last_posted_end_by_file::Dict{String, String} # fname → ISO end_time
end

StreamerState() = StreamerState(Dict(), Dict())

# ── ADB Helpers ─────────────────────────────────────────────────────

function adb_is_connected()::Bool
    try
        buf = IOBuffer()
        run(pipeline(`adb devices`, stdout=buf, stderr=buf))
        seekstart(buf)
        output = read(buf, String)

        # Split on \r\n explicitly
        lines = split(output, "\r\n")

        for line in lines
            # Skip empty lines and header
            isempty(strip(line))            && continue
            startswith(line, "List")        && continue

            # Check if line contains "device" after a tab
            parts = split(line, "\t")
            if length(parts) >= 2 && strip(parts[2]) == "device"
                return true
            end
        end
        return false
    catch e
        println("ADB check error: $e")
        return false
    end
end


function adb_list_hr_files(android_dir::String)::Vector{String}
    try
        buf = IOBuffer()
        run(pipeline(`adb shell ls $android_dir`,
                     stdout = buf, stderr = devnull))
        seekstart(buf)
        lines = readlines(buf)
        files = filter(f -> endswith(f, ".txt") &&
                            occursin("_HR.txt", f),
                       strip.(lines))
        return sort(files)
    catch
        return String[]
    end
end


function adb_pull_file(android_path::String,
                       local_path::String)::Bool
    try
        result = run(pipeline(
            `adb pull $android_path $local_path`,
            stdout = devnull, stderr = devnull
        ))
        return result.exitcode == 0
    catch
        return false
    end
end

# ── File hash (MD5) ─────────────────────────────────────────────────

function file_hash(path::String)::String
    open(path, "r") do f
        bytes2hex(sha256(f))   # SHA256 — more robust than MD5
    end
end

# ── Data row struct ──────────────────────────────────────────────────

struct PolarRow
    timestamp::DateTime
    hr::Float64
    hrv::Float64
    br::Float64
end


function parse_polar_hr_file(path::String)::Vector{PolarRow}
    rows = PolarRow[]

    lines = readlines(path)

    for line in lines
        line = strip(line)
        isempty(line)                        && continue
        startswith(line, "Phone timestamp")  && continue
        startswith(line, "Polar_H10")        && continue

        parts = split(line, ";")
        length(parts) < 2                    && continue

        try
            ts  = DateTime(strip(parts[1]))  # parse ISO timestamp
            hr  = length(parts) > 1 && !isempty(strip(parts[2])) ?
                      parse(Float64, strip(parts[2])) : NaN
            hrv = length(parts) > 2 && !isempty(strip(parts[3])) ?
                      parse(Float64, strip(parts[3])) : NaN
            br  = length(parts) > 3 && !isempty(strip(parts[4])) ?
                      parse(Float64, strip(parts[4])) : NaN

            isnan(hr) && continue            # hr required
            push!(rows, PolarRow(ts, hr, hrv, br))
        catch
            continue
        end
    end

    return rows
end

# ── Resample to 1s grid + interpolate ───────────────────────────────

"""
Linear interpolation over NaN gaps, with a max gap limit.
Equivalent to pandas interpolate(method='time', limit=N)
"""
function interpolate_limit(vals::Vector{Float64},
                            limit::Int)::Vector{Float64}
    out = copy(vals)
    n   = length(out)
    i   = 1
    while i <= n
        if isnan(out[i])
            # Find end of gap
            j = i
            while j <= n && isnan(out[j])
                j += 1
            end
            gap_len = j - i

            if gap_len <= limit
                # Safe left value
                left  = i > 1 ? out[i-1] : NaN
                # Safe right value
                right = j <= n ? out[j] : NaN

                if !isnan(left) && !isnan(right)
                    # Linear interpolation
                    for k in i:(j-1)
                        t = Float64(k - i + 1) /
                            Float64(gap_len + 1)
                        out[k] = left + t * (right - left)
                    end
                elseif !isnan(left)
                    out[i:(j-1)] .= left
                elseif !isnan(right)
                    out[i:(j-1)] .= right
                end
            end
            i = j
        else
            i += 1
        end
    end
    return out
end


"""
Rolling standard deviation with a minimum period.
Equivalent to pandas rolling(window).std(min_periods=N)
"""
function rolling_std(vals::Vector{Float64},
                     window::Int,
                     min_periods::Int)::Vector{Float64}
    n   = length(vals)
    out = fill(NaN, n)
    for i in 1:n
        start = max(1, i - window + 1)
        chunk = filter(!isnan, vals[start:i])
        if length(chunk) >= min_periods
            out[i] = std(chunk)
        end
    end
    return out
end


"""
Rolling mean with a minimum period.
"""
function rolling_mean(vals::Vector{Float64},
                      window::Int,
                      min_periods::Int)::Vector{Float64}
    n   = length(vals)
    out = fill(NaN, n)
    for i in 1:n
        start = max(1, i - window + 1)
        chunk = filter(!isnan, vals[start:i])
        if length(chunk) >= min_periods
            out[i] = mean(chunk)
        end
    end
    return out
end


"""
Clamp values to [lo, hi].
"""
clamp_vals(v::Vector{Float64}, lo, hi) =
    [isnan(x) ? NaN : clamp(x, lo, hi) for x in v]


"""
Full resample + clean + interpolate pipeline.
Equivalent to the pandas block in parse_polar_hr_file (Python).
Returns: (timestamps, hr, hrv, br) all Vector{Float64}
         timestamps as Vector{DateTime}
"""
function resample_and_clean(rows::Vector{PolarRow})
    isempty(rows) && return DateTime[], Float64[], Float64[], Float64[]

    # Sort by timestamp
    sorted = sort(rows, by = r -> r.timestamp)

    # Build 1-second grid
    t_start = sorted[1].timestamp
    t_end   = sorted[end].timestamp
    grid    = t_start:Second(1):t_end
    n       = length(grid)
    n == 0  && return DateTime[], Float64[], Float64[], Float64[]

    # Initialize grids with NaN
    hr_grid  = fill(NaN, n)
    hrv_grid = fill(NaN, n)
    br_grid  = fill(NaN, n)

    # Map rows onto 1s grid (average if multiple fall in same second)
    counts = zeros(Int, n)
    for row in sorted
        idx = round(Int, (row.timestamp - t_start).value / 1000) + 1
        idx = clamp(idx, 1, n)
        if isnan(hr_grid[idx])
            hr_grid[idx]  = row.hr
            hrv_grid[idx] = row.hrv
            br_grid[idx]  = row.br
            counts[idx]   = 1
        else
            hr_grid[idx]  += row.hr
            hrv_grid[idx] += isnan(row.hrv) ? 0.0 : row.hrv
            br_grid[idx]  += isnan(row.br)  ? 0.0 : row.br
            counts[idx]   += 1
        end
    end
    for i in 1:n
        if counts[i] > 1
            hr_grid[i]  /= counts[i]
            hrv_grid[i] /= counts[i]
            br_grid[i]  /= counts[i]
        end
    end

    # ── Apply valid ranges ───────────────────────────────────────────
    for i in 1:n
        if !isnan(hr_grid[i])  && (hr_grid[i]  < HR_MIN  || hr_grid[i]  > HR_MAX)
            hr_grid[i]  = NaN
        end
        if !isnan(hrv_grid[i]) && (hrv_grid[i] < HRV_MIN || hrv_grid[i] > HRV_MAX)
            hrv_grid[i] = NaN
        end
        if !isnan(br_grid[i])  && (br_grid[i]  < BR_MIN  || br_grid[i]  > BR_MAX)
            br_grid[i]  = NaN
        end
    end

    # ── HR: interpolate (limit=10) ───────────────────────────────────
    hr_grid = interpolate_limit(hr_grid, 10)

    # ── HRV: estimate if >50% missing, then interpolate ─────────────
    hrv_nan_frac = count(isnan, hrv_grid) / n
    if hrv_nan_frac > 0.5
        hr_std   = rolling_std(hr_grid, 60, 10)
        est_hrv  = clamp_vals(hr_std .* 12.0, HRV_EST_MIN, HRV_EST_MAX)
        for i in 1:n
            if isnan(hrv_grid[i]) && !isnan(est_hrv[i])
                hrv_grid[i] = est_hrv[i]
            end
        end
    end
    hrv_grid = interpolate_limit(hrv_grid, 20)

    # ── BR: estimate if >50% missing, then interpolate ──────────────
    br_nan_frac = count(isnan, br_grid) / n
    if br_nan_frac > 0.5
        hr_smooth = rolling_mean(hr_grid, 30, 5)
        valid_smooth = filter(!isnan, hr_smooth)
        if !isempty(valid_smooth)
            hr_min = quantile(valid_smooth, 0.05)
            hr_max = quantile(valid_smooth, 0.95)
            denom  = max(1e-6, hr_max - hr_min)
            for i in 1:n
                if isnan(br_grid[i]) && !isnan(hr_smooth[i])
                    br_est      = 10.0 + (hr_smooth[i] - hr_min) * (10.0 / denom)
                    br_grid[i]  = clamp(br_est, BR_EST_MIN, BR_EST_MAX)
                end
            end
        end
    end
    br_grid = interpolate_limit(br_grid, 20)

    # ── Drop rows where any of hr/hrv/br still NaN ──────────────────
    valid_idx = [i for i in 1:n
                 if !isnan(hr_grid[i]) &&
                    !isnan(hrv_grid[i]) &&
                    !isnan(br_grid[i])]

    timestamps = collect(grid)[valid_idx]
    return timestamps,
           hr_grid[valid_idx],
           hrv_grid[valid_idx],
           br_grid[valid_idx]
end

# ── Window builder ───────────────────────────────────────────────────

struct DataWindow
    start_time :: String   # ISO8601
    end_time   :: String
    hr         :: Vector{Float64}
    hrv        :: Vector{Float64}
    br         :: Vector{Float64}
    avg_hr     :: Float64
    avg_hrv    :: Float64
    avg_br     :: Float64
end


function build_windows(timestamps::Vector{DateTime},
                       hr::Vector{Float64},
                       hrv::Vector{Float64},
                       br::Vector{Float64};
                       window_sec::Int = WINDOW_SECONDS,
                       stride_sec::Int = STRIDE_SECONDS)::Vector{DataWindow}

    n = length(timestamps)
    n < window_sec && return DataWindow[]

    windows = DataWindow[]
    s = 1
    while s + window_sec - 1 <= n
        e = s + window_sec - 1
        push!(windows, DataWindow(
            string(timestamps[s]),
            string(timestamps[e]),
            hr[s:e],
            hrv[s:e],
            br[s:e],
            round(mean(hr[s:e]),  digits=1),
            round(mean(hrv[s:e]), digits=1),
            round(mean(br[s:e]),  digits=1),
        ))
        s += stride_sec
    end
    return windows
end

# ── HTTP POST ────────────────────────────────────────────────────────

function post_windows(windows::Vector{DataWindow})::Bool
    isempty(windows) && return false
    try
        payload = JSON3.write(Dict(
            "windows" => [
                Dict(
                    "start_time" => w.start_time,
                    "end_time"   => w.end_time,
                    "hr"         => w.hr,
                    "hrv"        => w.hrv,
                    "br"         => w.br,
                    "avg_hr"     => w.avg_hr,
                    "avg_hrv"    => w.avg_hrv,
                    "avg_br"     => w.avg_br,
                ) for w in windows
            ]
        ))
        resp = HTTP.post(
            "$(BRAIN_API)/ingest",
            ["Content-Type" => "application/json"],
            payload;
            readtimeout = 20
        )
        if resp.status == 200
            data = JSON3.read(resp.body)
            println("  Ingested $(get(data, :ingested, 0)) windows")
            return true
        end
        println("  Ingest failed: $(resp.status)")
        return false
    catch e
        println("  Post error: $e")
        return false
    end
end

# ── Main watch loop ──────────────────────────────────────────────────

function watch()
    mkpath(LOCAL_TEMP)
    state = StreamerState()

    println("=" ^ 70)
    println("Polar Reader LIVE — Julia (30s window, 5s stride)")
    println("=" ^ 70)

    while true
        if !adb_is_connected()
            println("[$(Dates.format(now(),"HH:MM:SS"))] ADB not connected")
            sleep(POLL_INTERVAL)
            continue
        end

        files = adb_list_hr_files(ANDROID_POLAR_DIR)
        if isempty(files)
            println("[$(Dates.format(now(),"HH:MM:SS"))] No HR files")
            sleep(POLL_INTERVAL)
            continue
        end

        fname        = files[end]   # newest by name sort
        android_path = "$(ANDROID_POLAR_DIR)/$(fname)"
        local_path   = joinpath(LOCAL_TEMP, fname)

        ok = adb_pull_file(android_path, local_path)
        if !ok || !isfile(local_path)
            sleep(POLL_INTERVAL)
            continue
        end

        h = file_hash(local_path)
        if get(state.file_states, fname, "") == h
            sleep(POLL_INTERVAL)
            continue
        end
        state.file_states[fname] = h

        println("\n[$(Dates.format(now(),"HH:MM:SS"))] Updated: $(fname)")

        rows = parse_polar_hr_file(local_path)
        if isempty(rows)
            println("  Parse empty")
            sleep(POLL_INTERVAL)
            continue
        end

        # ── Recency filter (last 20 min) ─────────────────────────────
        cutoff = now() - Minute(RECENT_MINUTES)
        rows   = filter(r -> r.timestamp >= cutoff, rows)
        if isempty(rows)
            println("  No recent rows")
            sleep(POLL_INTERVAL)
            continue
        end

        # ── Resample + clean ─────────────────────────────────────────
        timestamps, hr, hrv, br = resample_and_clean(rows)
        if isempty(timestamps)
            println("  Resample empty")
            sleep(POLL_INTERVAL)
            continue
        end

        # ── Build windows ────────────────────────────────────────────
        windows = build_windows(timestamps, hr, hrv, br)
        if isempty(windows)
            println("  Not enough rows for first window yet")
            sleep(POLL_INTERVAL)
            continue
        end

        # ── Filter: only NEW windows ─────────────────────────────────
        last_end = get(state.last_posted_end_by_file, fname, "")
        new_windows = isempty(last_end) ? windows :
                      filter(w -> w.end_time > last_end, windows)

        if isempty(new_windows)
            println("  No NEW windows")
            sleep(POLL_INTERVAL)
            continue
        end

        # ── Filter: drop STALE windows ───────────────────────────────
        stale_cutoff = now() - Minute(STALE_WINDOW_MINUTES)
        fresh = filter(new_windows) do w
            w_end = DateTime(w.end_time)
            w_end >= stale_cutoff
        end

        if isempty(fresh)
            println("  New windows are stale")
            sleep(POLL_INTERVAL)
            continue
        end

        println("  Posting $(length(fresh)) windows | last_end=$(fresh[end].end_time)")
        ok = post_windows(fresh)
        if ok
            state.last_posted_end_by_file[fname] = fresh[end].end_time
        end

        sleep(POLL_INTERVAL)
    end
end

end # module DataStreamer