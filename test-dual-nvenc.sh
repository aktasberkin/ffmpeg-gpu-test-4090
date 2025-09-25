#!/bin/bash

# RTX 4090 Dual-NVENC Concurrent Stream Test Script
# Tests concurrent stream capacity using both NVENC encoders

set -e

# Configurable Parameters
STREAMS_PER_NVENC=${STREAMS_PER_NVENC:-50}
TOTAL_NVENC_ENCODERS=2
TOTAL_STREAMS=$((STREAMS_PER_NVENC * TOTAL_NVENC_ENCODERS))

# Directories
INPUT_DIR="./input"
OUTPUT_DIR="./output"
LOG_DIR="./logs"

# Test Configuration
TEST_DURATION=${TEST_DURATION:-60}
OUTPUT_RESOLUTION="1280x720"
OUTPUT_FRAMERATE=30
TARGET_BITRATE="2M"
HLS_SEGMENT_TIME=6

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_progress() { echo -e "${BLUE}[PROGRESS]${NC} $1"; }
print_nvenc() { echo -e "${MAGENTA}[NVENC]${NC} $1"; }

# Global variables for process management
NVENC1_PID=""
NVENC2_PID=""
MONITOR_PID=""

# Parse command line arguments
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <streams_per_nvenc> [duration_seconds]"
    echo ""
    echo "Parameters:"
    echo "  streams_per_nvenc: Number of streams per NVENC encoder (1-100)"
    echo "  duration_seconds:  Test duration in seconds (optional, default: 60)"
    echo ""
    echo "Examples:"
    echo "  $0 25      # 25 streams per NVENC (50 total), 60 seconds"
    echo "  $0 50 120  # 50 streams per NVENC (100 total), 120 seconds"
    echo "  $0 75      # 75 streams per NVENC (150 total), 60 seconds"
    echo ""
    echo "Predefined modes (for compatibility):"
    echo "  $0 conservative  # Same as: $0 25"
    echo "  $0 standard      # Same as: $0 50"
    echo "  $0 aggressive    # Same as: $0 75"
    echo "  $0 maximum       # Same as: $0 100"
    exit 1
fi

# Handle predefined mode names for backward compatibility
case $1 in
    "conservative") STREAMS_PER_NVENC=25 ;;
    "standard")     STREAMS_PER_NVENC=50 ;;
    "aggressive")   STREAMS_PER_NVENC=75 ;;
    "maximum")      STREAMS_PER_NVENC=100 ;;
    *)
        # Validate numeric input
        if ! [[ "$1" =~ ^[0-9]+$ ]]; then
            print_error "Invalid input: '$1' - must be a number or predefined mode"
            exit 1
        fi

        STREAMS_PER_NVENC=$1

        if [[ $STREAMS_PER_NVENC -lt 1 || $STREAMS_PER_NVENC -gt 100 ]]; then
            print_error "Streams per NVENC must be between 1 and 100"
            exit 1
        fi
        ;;
esac

# Optional duration parameter
if [[ $# -ge 2 ]]; then
    if [[ "$2" =~ ^[0-9]+$ ]]; then
        TEST_DURATION=$2
    else
        print_error "Invalid duration: '$2' - must be a number in seconds"
        exit 1
    fi
fi

# Recalculate total after mode selection
TOTAL_STREAMS=$((STREAMS_PER_NVENC * TOTAL_NVENC_ENCODERS))

print_status "RTX 4090 Dual-NVENC Concurrent Test"
print_status "Streams per NVENC: $STREAMS_PER_NVENC"
print_status "Total Streams: $TOTAL_STREAMS"
print_status "Test Duration: ${TEST_DURATION}s"

check_dependencies() {
    print_status "Checking dependencies..."

    # Check FFmpeg with NVENC support
    if ! command -v ffmpeg &> /dev/null; then
        print_error "FFmpeg not found"
        exit 1
    fi

    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
        print_error "FFmpeg NVENC support not available"
        exit 1
    fi

    # Check NVIDIA drivers
    if ! command -v nvidia-smi &> /dev/null; then
        print_error "NVIDIA drivers not available"
        exit 1
    fi

    # Check GPU
    local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null)
    if [[ ! "$gpu_name" == *"RTX 4090"* ]]; then
        print_warning "GPU is not RTX 4090: $gpu_name"
        print_warning "Test may not be accurate for this GPU"
    fi

    # Check available VRAM
    local available_vram=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null)
    local required_vram=$((TOTAL_STREAMS * 170))  # ~170MB per stream

    if [ $available_vram -lt $required_vram ]; then
        print_error "Insufficient VRAM: ${available_vram}MB available, ${required_vram}MB required"
        exit 1
    fi

    print_status "Dependencies OK"
    print_status "GPU: $gpu_name"
    print_status "Available VRAM: ${available_vram}MB"
}

setup_directories() {
    print_status "Setting up directories..."

    # Create directory structure
    mkdir -p "$OUTPUT_DIR"/{nvenc1,nvenc2}
    mkdir -p "$LOG_DIR"

    # Create individual stream directories
    for i in $(seq -f "%03g" 1 $STREAMS_PER_NVENC); do
        mkdir -p "$OUTPUT_DIR/nvenc1/stream$i"
    done

    for i in $(seq -f "%03g" $((STREAMS_PER_NVENC + 1)) $TOTAL_STREAMS); do
        mkdir -p "$OUTPUT_DIR/nvenc2/stream$i"
    done

    # Clean previous logs
    rm -f "$LOG_DIR"/*.log

    print_status "Directory structure ready"
}

validate_inputs() {
    print_status "Validating input videos..."

    local missing_count=0
    for i in $(seq -f "%03g" 1 $TOTAL_STREAMS); do
        local input_file="$INPUT_DIR/test_video_$i.mp4"
        if [ ! -f "$input_file" ]; then
            print_error "Missing input: $input_file"
            ((missing_count++))
        fi
    done

    if [ $missing_count -gt 0 ]; then
        print_error "$missing_count input files missing"
        print_status "Run './create-test-videos.sh $TOTAL_STREAMS' to create inputs"
        exit 1
    fi

    print_status "All $TOTAL_STREAMS input videos validated"
}

build_ffmpeg_command() {
    local process_id=$1
    local start_stream=$2
    local end_stream=$3
    local output_base_dir=$4

    local cmd="ffmpeg"

    # Input optimization parameters
    cmd="$cmd -analyzeduration 10M -probesize 50M"
    cmd="$cmd -fflags +genpts+igndts -avoid_negative_ts make_zero"

    # Hardware acceleration
    cmd="$cmd -hwaccel cuda -hwaccel_device 0 -hwaccel_output_format cuda"
    cmd="$cmd -threads 1 -thread_queue_size 512"

    # Add all input files
    for i in $(seq -f "%03g" $start_stream $end_stream); do
        cmd="$cmd -i $INPUT_DIR/test_video_$i.mp4"
    done

    # Build filter complex for scaling
    local filter_complex=""
    local input_index=0
    for i in $(seq -f "%03g" $start_stream $end_stream); do
        if [ $input_index -gt 0 ]; then
            filter_complex="$filter_complex;"
        fi
        filter_complex="$filter_complex[$input_index:v]scale_cuda=$OUTPUT_RESOLUTION:force_original_aspect_ratio=decrease,fps=$OUTPUT_FRAMERATE[v$input_index]"
        ((input_index++))
    done

    cmd="$cmd -filter_complex \"$filter_complex\""

    # Add output mappings
    input_index=0
    for i in $(seq -f "%03g" $start_stream $end_stream); do
        cmd="$cmd -map \"[v$input_index]\""
        cmd="$cmd -c:v h264_nvenc -preset p4 -rc cbr"
        cmd="$cmd -b:v $TARGET_BITRATE -maxrate $TARGET_BITRATE -bufsize $((${TARGET_BITRATE%M} * 4))M"
        cmd="$cmd -r $OUTPUT_FRAMERATE -max_muxing_queue_size 1024"
        cmd="$cmd -f hls -hls_time $HLS_SEGMENT_TIME -hls_playlist_type event"
        cmd="$cmd -hls_segment_filename \"$output_base_dir/stream$i/segment_%03d.ts\""
        cmd="$cmd \"$output_base_dir/stream$i/playlist.m3u8\""
        ((input_index++))
    done

    echo "$cmd"
}

start_monitoring() {
    print_status "Starting GPU monitoring..."

    # Start continuous monitoring
    {
        while true; do
            local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo "0")
            local mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "0")
            local mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "1")
            local temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "0")
            local power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null || echo "0")

            local mem_percent=$((mem_used * 100 / mem_total))

            echo "$timestamp,$gpu_util,$mem_used,$mem_total,$mem_percent,$temp,$power" >> "$LOG_DIR/gpu_monitoring.csv"
            sleep 1
        done
    } &
    MONITOR_PID=$!

    # Initialize monitoring CSV
    echo "timestamp,gpu_util_percent,mem_used_mb,mem_total_mb,mem_percent,temp_c,power_w" > "$LOG_DIR/gpu_monitoring.csv"
}

stop_monitoring() {
    if [ ! -z "$MONITOR_PID" ]; then
        kill $MONITOR_PID 2>/dev/null || true
        wait $MONITOR_PID 2>/dev/null || true
        MONITOR_PID=""
        print_status "GPU monitoring stopped"
    fi
}

launch_nvenc_process() {
    local process_id=$1
    local start_stream=$2
    local end_stream=$3
    local output_dir="$OUTPUT_DIR/nvenc$process_id"
    local log_file="$LOG_DIR/nvenc${process_id}_process.log"

    print_nvenc "Process $process_id: Preparing to launch streams $start_stream-$end_stream"

    # Set memory limits for the process
    ulimit -v 10485760  # 10GB virtual memory
    ulimit -m 8388608   # 8GB resident memory

    # Build and execute FFmpeg command
    local ffmpeg_cmd=$(build_ffmpeg_command $process_id $start_stream $end_stream $output_dir)

    print_nvenc "Process $process_id: Starting FFmpeg with $((end_stream - start_stream + 1)) concurrent streams"

    # Execute FFmpeg in background
    {
        echo "Started at: $(date)"
        echo "Command: $ffmpeg_cmd"
        echo "----------------------------------------"
        eval "$ffmpeg_cmd" -t $TEST_DURATION
        local exit_code=$?
        echo "----------------------------------------"
        echo "Completed at: $(date)"
        echo "Exit code: $exit_code"
        exit $exit_code
    } > "$log_file" 2>&1 &

    if [ $process_id -eq 1 ]; then
        NVENC1_PID=$!
    else
        NVENC2_PID=$!
    fi

    print_nvenc "Process $process_id: Started with PID ${!} (logging to $(basename $log_file))"
}

monitor_processes() {
    print_status "Monitoring concurrent processes..."

    local start_time=$(date +%s)
    local nvenc1_status="running"
    local nvenc2_status="running"

    while [ "$nvenc1_status" = "running" ] || [ "$nvenc2_status" = "running" ]; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Check process status
        if [ ! -z "$NVENC1_PID" ] && [ "$nvenc1_status" = "running" ]; then
            if ! kill -0 $NVENC1_PID 2>/dev/null; then
                wait $NVENC1_PID
                local exit1=$?
                nvenc1_status="completed"
                if [ $exit1 -eq 0 ]; then
                    print_nvenc "Process 1: ✓ Completed successfully"
                else
                    print_nvenc "Process 1: ✗ Failed (exit code: $exit1)"
                fi
            fi
        fi

        if [ ! -z "$NVENC2_PID" ] && [ "$nvenc2_status" = "running" ]; then
            if ! kill -0 $NVENC2_PID 2>/dev/null; then
                wait $NVENC2_PID
                local exit2=$?
                nvenc2_status="completed"
                if [ $exit2 -eq 0 ]; then
                    print_nvenc "Process 2: ✓ Completed successfully"
                else
                    print_nvenc "Process 2: ✗ Failed (exit code: $exit2)"
                fi
            fi
        fi

        # Show progress every 10 seconds
        if [ $((elapsed % 10)) -eq 0 ]; then
            print_progress "Elapsed: ${elapsed}s / ${TEST_DURATION}s | NVENC1: $nvenc1_status | NVENC2: $nvenc2_status"
        fi

        sleep 1
    done

    local total_time=$(($(date +%s) - start_time))
    print_status "Both processes completed in ${total_time}s"

    return 0
}

analyze_results() {
    print_status "Analyzing test results..."

    local success_count=0
    local total_expected_outputs=$TOTAL_STREAMS

    # Check output files
    for i in $(seq -f "%03g" 1 $STREAMS_PER_NVENC); do
        local playlist_file="$OUTPUT_DIR/nvenc1/stream$i/playlist.m3u8"
        if [ -f "$playlist_file" ] && [ -s "$playlist_file" ]; then
            ((success_count++))
        fi
    done

    for i in $(seq -f "%03g" $((STREAMS_PER_NVENC + 1)) $TOTAL_STREAMS); do
        local playlist_file="$OUTPUT_DIR/nvenc2/stream$i/playlist.m3u8"
        if [ -f "$playlist_file" ] && [ -s "$playlist_file" ]; then
            ((success_count++))
        fi
    done

    local success_rate=$((success_count * 100 / total_expected_outputs))

    # Calculate total output size
    local total_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)

    # Generate summary
    local summary_file="$LOG_DIR/test_summary.txt"
    cat > "$summary_file" << EOF
RTX 4090 Dual-NVENC Concurrent Stream Test Results
================================================
Test Date: $(date)
Streams per NVENC: $STREAMS_PER_NVENC
Test Duration: ${TEST_DURATION}s

Configuration:
- Streams per NVENC: $STREAMS_PER_NVENC
- Total Streams: $TOTAL_STREAMS
- Output Resolution: $OUTPUT_RESOLUTION
- Output Frame Rate: ${OUTPUT_FRAMERATE}fps
- Target Bitrate: $TARGET_BITRATE

Results:
- Successful Streams: $success_count / $total_expected_outputs
- Success Rate: ${success_rate}%
- Total Output Size: $total_size

Log Files:
- NVENC1 Process: $(ls -la "$LOG_DIR/nvenc1_process.log" 2>/dev/null | awk '{print $5 " bytes"}' || echo "not found")
- NVENC2 Process: $(ls -la "$LOG_DIR/nvenc2_process.log" 2>/dev/null | awk '{print $5 " bytes"}' || echo "not found")
- GPU Monitoring: $(wc -l < "$LOG_DIR/gpu_monitoring.csv" 2>/dev/null || echo "0") data points

Output Directories:
- NVENC1 Streams: $OUTPUT_DIR/nvenc1/ (streams 001-$(printf "%03d" $STREAMS_PER_NVENC))
- NVENC2 Streams: $OUTPUT_DIR/nvenc2/ (streams $(printf "%03d" $((STREAMS_PER_NVENC + 1)))-$(printf "%03d" $TOTAL_STREAMS))
EOF

    print_status "Test Summary:"
    echo "=================================="
    echo "Success Rate: ${success_rate}% ($success_count/$total_expected_outputs streams)"
    echo "Total Output: $total_size"
    echo "Summary saved: $summary_file"
    echo "=================================="

    if [ $success_rate -ge 95 ]; then
        print_status "✓ Test PASSED (≥95% success rate)"
        return 0
    else
        print_warning "⚠ Test MARGINAL (<95% success rate)"
        return 1
    fi
}

cleanup() {
    print_status "Cleaning up..."

    # Stop monitoring
    stop_monitoring

    # Kill FFmpeg processes if still running
    if [ ! -z "$NVENC1_PID" ]; then
        kill $NVENC1_PID 2>/dev/null || true
        wait $NVENC1_PID 2>/dev/null || true
    fi

    if [ ! -z "$NVENC2_PID" ]; then
        kill $NVENC2_PID 2>/dev/null || true
        wait $NVENC2_PID 2>/dev/null || true
    fi

    # Kill any remaining FFmpeg processes
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true

    # Reset GPU if possible
    nvidia-smi -r 2>/dev/null || true

    print_status "Cleanup completed"
}

main() {
    print_status "Starting RTX 4090 Dual-NVENC Concurrent Test"

    # Set cleanup trap
    trap cleanup EXIT

    # Pre-test validation
    check_dependencies
    setup_directories
    validate_inputs

    # Start monitoring
    start_monitoring

    # Launch concurrent processes
    print_status "Launching dual concurrent processes..."

    # Process 1: Streams 1 to STREAMS_PER_NVENC
    launch_nvenc_process 1 1 $STREAMS_PER_NVENC

    # Small delay to stagger startup slightly
    sleep 2

    # Process 2: Streams (STREAMS_PER_NVENC+1) to TOTAL_STREAMS
    launch_nvenc_process 2 $((STREAMS_PER_NVENC + 1)) $TOTAL_STREAMS

    # Monitor both processes
    monitor_processes

    # Stop monitoring
    stop_monitoring

    # Analyze results
    analyze_results
    local test_result=$?

    print_status "Test completed. Check logs in $LOG_DIR/ for details."

    exit $test_result
}

# Run main function
main