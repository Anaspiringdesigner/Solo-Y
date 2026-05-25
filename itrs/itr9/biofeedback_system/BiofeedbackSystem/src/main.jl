include("data_streamer.jl")
using .DataStreamer

# Test 1: ADB connection
println("ADB connected: ", DataStreamer.adb_is_connected())

# Test 2: List files
files = DataStreamer.adb_list_hr_files(DataStreamer.ANDROID_POLAR_DIR)
println("Files found: ", files)

# Test 3: Full watch loop (runs forever, Ctrl+C to stop)
DataStreamer.watch()