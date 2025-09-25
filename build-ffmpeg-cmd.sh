#!/bin/bash

# RTX 4090 FFmpeg Command Builder for Concurrent Streams
# Generates optimized FFmpeg commands for dual-NVENC testing

set -e

# Default configuration
DEFAULT_RESOLUTION="1280x720"
DEFAULT_FRAMERATE="30"
DEFAULT_BITRATE="2M"
DEFAULT_PRESET="p4"
DEFAULT_HLS_SEGMENT_TIME="6"

show_help() {
    cat << EOF
RTX 4090 FFmpeg Command Builder
===============================

Usage: $0 [OPTIONS]

OPTIONS:
  -s, --start-stream NUM      Starting stream number (default: 1)
  -e, --end-stream NUM        Ending stream number (default: 50)
  -i, --input-dir DIR         Input directory (default: ./input)
  -o, --output-dir DIR        Output directory (default: ./output/nvenc1)
  -r, --resolution WIDTHxHEIGHT Output resolution (default: 1280x720)
  -f, --framerate FPS         Output framerate (default: 30)
  -b, --bitrate RATE          Target bitrate (default: 2M)
  -p, --preset PRESET         NVENC preset (default: p4)
  -t, --hls-time SECONDS      HLS segment time (default: 6)
  -d, --duration SECONDS      Test duration (optional)
  --dry-run                   Show command without executing
  --execute                   Execute the generated command
  --save-to-file FILE         Save command to file
  -h, --help                  Show this help

EXAMPLES:
  # Build command for streams 1-50
  $0 -s 1 -e 50 --dry-run

  # Build command for NVENC2 with streams 51-100
  $0 -s 51 -e 100 -o ./output/nvenc2 --dry-run

  # Generate and execute command for 25 streams
  $0 -e 25 --execute

  # Custom resolution and bitrate
  $0 -r 1920x1080 -b 4M --dry-run

  # Save command to script file
  $0 --save-to-file run_nvenc1.sh
EOF
}

# Parse command line arguments
START_STREAM=1
END_STREAM=50
INPUT_DIR="./input"
OUTPUT_DIR="./output/nvenc1"
RESOLUTION="$DEFAULT_RESOLUTION"
FRAMERATE="$DEFAULT_FRAMERATE"
BITRATE="$DEFAULT_BITRATE"
PRESET="$DEFAULT_PRESET"
HLS_SEGMENT_TIME="$DEFAULT_HLS_SEGMENT_TIME"
DURATION=""
DRY_RUN=false
EXECUTE=false
SAVE_TO_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--start-stream)
            START_STREAM="$2"
            shift 2
            ;;
        -e|--end-stream)
            END_STREAM="$2"
            shift 2
            ;;
        -i|--input-dir)
            INPUT_DIR="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -r|--resolution)
            RESOLUTION="$2"
            shift 2
            ;;
        -f|--framerate)
            FRAMERATE="$2"
            shift 2
            ;;
        -b|--bitrate)
            BITRATE="$2"
            shift 2
            ;;
        -p|--preset)
            PRESET="$2"
            shift 2
            ;;
        -t|--hls-time)
            HLS_SEGMENT_TIME="$2"
            shift 2
            ;;
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --execute)
            EXECUTE=true
            shift
            ;;
        --save-to-file)
            SAVE_TO_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate inputs
if [[ $START_STREAM -gt $END_STREAM ]]; then
    echo "Error: Start stream ($START_STREAM) cannot be greater than end stream ($END_STREAM)"
    exit 1
fi

if [[ $START_STREAM -lt 1 || $END_STREAM -lt 1 ]]; then
    echo "Error: Stream numbers must be positive"
    exit 1
fi

STREAM_COUNT=$((END_STREAM - START_STREAM + 1))

# Validate FFmpeg availability
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: FFmpeg not found"
    exit 1
fi

echo "RTX 4090 FFmpeg Command Builder"
echo "================================"
echo "Streams: $START_STREAM to $END_STREAM ($STREAM_COUNT streams)"
echo "Input Dir: $INPUT_DIR"
echo "Output Dir: $OUTPUT_DIR"
echo "Resolution: $RESOLUTION @ ${FRAMERATE}fps"
echo "Bitrate: $BITRATE (preset: $PRESET)"
echo "HLS Segment Time: ${HLS_SEGMENT_TIME}s"
if [[ -n "$DURATION" ]]; then
    echo "Duration: ${DURATION}s"
fi
echo ""

build_ffmpeg_command() {
    local cmd="ffmpeg"

    # Input optimization parameters
    cmd="$cmd -analyzeduration 10M -probesize 50M"
    cmd="$cmd -fflags +genpts+igndts -avoid_negative_ts make_zero"

    # Hardware acceleration
    cmd="$cmd -hwaccel cuda -hwaccel_device 0 -hwaccel_output_format cuda"
    cmd="$cmd -threads 1 -thread_queue_size 512"

    # Add all input files
    local input_list=""
    for i in $(seq -f "%03g" $START_STREAM $END_STREAM); do
        input_list="$input_list -i $INPUT_DIR/test_video_$i.mp4"
    done
    cmd="$cmd$input_list"

    # Build filter complex for GPU scaling
    local filter_complex=""
    local input_index=0
    for i in $(seq $START_STREAM $END_STREAM); do
        if [[ $input_index -gt 0 ]]; then
            filter_complex="$filter_complex;"
        fi
        filter_complex="$filter_complex[$input_index:v]scale_cuda=$RESOLUTION:force_original_aspect_ratio=decrease,fps=$FRAMERATE[v$input_index]"
        ((input_index++))
    done
    cmd="$cmd -filter_complex \"$filter_complex\""

    # Add output mappings for each stream
    input_index=0
    local bufsize=$((${BITRATE%M} * 4))M
    for i in $(seq -f "%03g" $START_STREAM $END_STREAM); do
        # Map video stream
        cmd="$cmd -map \"[v$input_index]\""

        # NVENC encoding parameters
        cmd="$cmd -c:v h264_nvenc -preset $PRESET -rc cbr"
        cmd="$cmd -b:v $BITRATE -maxrate $BITRATE -bufsize $bufsize"
        cmd="$cmd -r $FRAMERATE -max_muxing_queue_size 1024"

        # HLS output parameters
        cmd="$cmd -f hls -hls_time $HLS_SEGMENT_TIME -hls_playlist_type event"
        cmd="$cmd -hls_segment_filename \"$OUTPUT_DIR/stream$i/segment_%03d.ts\""
        cmd="$cmd \"$OUTPUT_DIR/stream$i/playlist.m3u8\""

        ((input_index++))
    done

    # Add duration if specified
    if [[ -n "$DURATION" ]]; then
        cmd="$cmd -t $DURATION"
    fi

    echo "$cmd"
}

create_output_directories() {
    echo "Creating output directories..."
    for i in $(seq -f "%03g" $START_STREAM $END_STREAM); do
        mkdir -p "$OUTPUT_DIR/stream$i"
    done
    echo "Created $STREAM_COUNT stream directories"
}

validate_inputs() {
    echo "Validating input files..."
    local missing_count=0
    local missing_files=()

    for i in $(seq -f "%03g" $START_STREAM $END_STREAM); do
        local input_file="$INPUT_DIR/test_video_$i.mp4"
        if [[ ! -f "$input_file" ]]; then
            ((missing_count++))
            missing_files+=("$input_file")
        fi
    done

    if [[ $missing_count -gt 0 ]]; then
        echo "Error: $missing_count input files are missing:"
        for file in "${missing_files[@]:0:5}"; do  # Show first 5 missing files
            echo "  - $file"
        done
        if [[ $missing_count -gt 5 ]]; then
            echo "  ... and $((missing_count - 5)) more"
        fi
        echo ""
        echo "Run './create-test-videos.sh $END_STREAM' to create missing inputs"
        return 1
    fi

    echo "All $STREAM_COUNT input files validated"
    return 0
}

# Build the FFmpeg command
FFMPEG_CMD=$(build_ffmpeg_command)

# Handle different execution modes
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Generated FFmpeg Command:"
    echo "========================="
    echo "$FFMPEG_CMD"
    echo ""
    echo "Command length: ${#FFMPEG_CMD} characters"
    echo "Input streams: $STREAM_COUNT"
    echo "Estimated VRAM usage: $((STREAM_COUNT * 170))MB"

elif [[ -n "$SAVE_TO_FILE" ]]; then
    create_output_directories

    echo "Saving command to file: $SAVE_TO_FILE"

    cat > "$SAVE_TO_FILE" << EOF
#!/bin/bash
# RTX 4090 FFmpeg Command - Generated $(date)
# Streams: $START_STREAM to $END_STREAM ($STREAM_COUNT concurrent streams)
# Configuration: $RESOLUTION @ ${FRAMERATE}fps, ${BITRATE} bitrate

set -e

echo "Starting RTX 4090 concurrent stream test..."
echo "Streams: $STREAM_COUNT concurrent"
echo "Start time: \$(date)"

$FFMPEG_CMD

echo "Completed at: \$(date)"
EOF

    chmod +x "$SAVE_TO_FILE"
    echo "Executable script saved to: $SAVE_TO_FILE"
    echo ""
    echo "To run: ./$SAVE_TO_FILE"

elif [[ "$EXECUTE" == "true" ]]; then
    echo "Preparing to execute FFmpeg command..."

    if ! validate_inputs; then
        exit 1
    fi

    create_output_directories

    echo ""
    echo "Starting concurrent stream processing..."
    echo "Start time: $(date)"
    echo ""

    # Execute the command
    eval "$FFMPEG_CMD"

    echo ""
    echo "Completed at: $(date)"

else
    echo "No execution mode specified. Use --dry-run, --execute, or --save-to-file"
    echo "Run '$0 --help' for usage information"
fi