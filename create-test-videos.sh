#!/bin/bash

# RTX 4090 Dual-NVENC Test - Input Video Generation Script
# Creates test videos for concurrent stream testing

set -e

# Configuration
TOTAL_VIDEOS=${1:-100}
VIDEO_DURATION=${2:-120}
INPUT_DIR="./input"
RESOLUTION="1920x1080"
FRAMERATE=30

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_progress() { echo -e "${BLUE}[PROGRESS]${NC} $1"; }

check_dependencies() {
    print_status "Checking dependencies..."

    if ! command -v ffmpeg &> /dev/null; then
        print_error "FFmpeg not found"
        exit 1
    fi

    # Check available disk space (need ~2GB for 100 videos)
    local available_space=$(df . | tail -1 | awk '{print $4}')
    local required_space=$((TOTAL_VIDEOS * 20 * 1024))  # ~20MB per video

    if [ $available_space -lt $required_space ]; then
        print_error "Insufficient disk space. Required: $(($required_space/1024/1024))GB"
        exit 1
    fi

    print_status "Dependencies OK"
}

setup_directories() {
    print_status "Setting up directories..."
    mkdir -p "$INPUT_DIR"
}

create_test_video() {
    local video_num=$1
    local video_file="$INPUT_DIR/test_video_$(printf "%03d" $video_num).mp4"

    # Skip if video already exists and is valid
    if [ -f "$video_file" ]; then
        # Quick validation - check if file has expected duration
        local duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$video_file" 2>/dev/null | cut -d'.' -f1)
        if [ "$duration" = "$VIDEO_DURATION" ]; then
            return 0  # Video exists and valid
        else
            print_warning "Recreating invalid video: $(basename $video_file)"
            rm -f "$video_file"
        fi
    fi

    # Calculate unique frequency for audio (1000Hz + video_num * 50)
    local frequency=$(( (video_num - 1) * 50 + 1000 ))

    # Create test video with unique visual and audio patterns
    ffmpeg -y \
        -f lavfi -i "testsrc2=size=${RESOLUTION}:rate=${FRAMERATE}:duration=${VIDEO_DURATION}" \
        -f lavfi -i "sine=frequency=${frequency}:sample_rate=48000:duration=${VIDEO_DURATION}" \
        -c:v libx264 -preset fast -crf 23 \
        -c:a aac -b:a 128k \
        -pix_fmt yuv420p \
        -movflags +faststart \
        "$video_file" \
        &> /dev/null

    if [ $? -eq 0 ]; then
        return 0
    else
        print_error "Failed to create video: $(basename $video_file)"
        return 1
    fi
}

create_videos_batch() {
    local start_num=$1
    local end_num=$2
    local failed_count=0

    for i in $(seq $start_num $end_num); do
        if ! create_test_video $i; then
            ((failed_count++))
        fi
    done

    return $failed_count
}

create_all_videos() {
    print_status "Creating $TOTAL_VIDEOS test videos..."
    print_status "Video specs: ${RESOLUTION}@${FRAMERATE}fps, ${VIDEO_DURATION}s duration"

    local batch_size=10
    local total_batches=$(( (TOTAL_VIDEOS + batch_size - 1) / batch_size ))
    local batch_num=0
    local total_failed=0

    for ((start=1; start<=TOTAL_VIDEOS; start+=batch_size)); do
        local end=$((start + batch_size - 1))
        if [ $end -gt $TOTAL_VIDEOS ]; then
            end=$TOTAL_VIDEOS
        fi

        ((batch_num++))
        print_progress "Batch $batch_num/$total_batches: Creating videos $(printf "%03d" $start)-$(printf "%03d" $end)..."

        # Run batch creation in parallel
        local pids=()
        for i in $(seq $start $end); do
            create_test_video $i &
            pids+=($!)
        done

        # Wait for batch completion and count failures
        local batch_failed=0
        for pid in "${pids[@]}"; do
            if ! wait $pid; then
                ((batch_failed++))
            fi
        done

        total_failed=$((total_failed + batch_failed))

        if [ $batch_failed -gt 0 ]; then
            print_warning "Batch $batch_num: $batch_failed videos failed"
        fi

        # Progress indicator
        local progress=$(( batch_num * 100 / total_batches ))
        print_progress "Progress: ${progress}% (${batch_num}/${total_batches} batches)"
    done

    if [ $total_failed -gt 0 ]; then
        print_error "Total failed videos: $total_failed"
        return 1
    else
        print_status "All $TOTAL_VIDEOS videos created successfully"
        return 0
    fi
}

verify_videos() {
    print_status "Verifying created videos..."

    local valid_count=0
    local invalid_count=0

    for i in $(seq 1 $TOTAL_VIDEOS); do
        local video_file="$INPUT_DIR/test_video_$(printf "%03d" $i).mp4"

        if [ -f "$video_file" ]; then
            # Quick verification
            local duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$video_file" 2>/dev/null | cut -d'.' -f1)
            if [ "$duration" = "$VIDEO_DURATION" ]; then
                ((valid_count++))
            else
                print_warning "Invalid duration in video $(printf "%03d" $i): ${duration}s (expected: ${VIDEO_DURATION}s)"
                ((invalid_count++))
            fi
        else
            print_error "Missing video file: test_video_$(printf "%03d" $i).mp4"
            ((invalid_count++))
        fi
    done

    print_status "Verification complete: $valid_count valid, $invalid_count invalid"

    if [ $invalid_count -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

show_summary() {
    print_status "Video Generation Summary:"
    echo "----------------------------------------"
    echo "Total videos: $TOTAL_VIDEOS"
    echo "Resolution: $RESOLUTION"
    echo "Frame rate: ${FRAMERATE}fps"
    echo "Duration: ${VIDEO_DURATION}s each"
    echo "Directory: $INPUT_DIR"

    # Calculate total size
    local total_size=$(du -sh "$INPUT_DIR" 2>/dev/null | cut -f1)
    echo "Total size: $total_size"

    # Show some sample files
    echo ""
    echo "Sample files:"
    ls -lh "$INPUT_DIR" | head -5 | tail -4
    echo "..."
    echo "----------------------------------------"
}

# Main execution
main() {
    print_status "RTX 4090 Test Video Generator"
    print_status "Creating $TOTAL_VIDEOS videos, ${VIDEO_DURATION}s each"

    check_dependencies
    setup_directories

    local start_time=$(date +%s)

    if create_all_videos; then
        if verify_videos; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            print_status "✓ Video generation completed successfully in ${duration}s"
            show_summary
        else
            print_error "Video verification failed"
            exit 1
        fi
    else
        print_error "Video generation failed"
        exit 1
    fi
}

# Help function
show_help() {
    echo "Usage: $0 [VIDEO_COUNT] [DURATION_SECONDS]"
    echo ""
    echo "Examples:"
    echo "  $0              # Create 100 videos, 120s each (default)"
    echo "  $0 50           # Create 50 videos, 120s each"
    echo "  $0 200 60       # Create 200 videos, 60s each"
    echo ""
    echo "Options:"
    echo "  VIDEO_COUNT     : Number of videos to create (default: 100)"
    echo "  DURATION_SECONDS: Duration of each video (default: 120)"
}

# Parse arguments
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Validate arguments
if [[ $TOTAL_VIDEOS -lt 1 || $TOTAL_VIDEOS -gt 1000 ]]; then
    print_error "Video count must be between 1 and 1000"
    exit 1
fi

if [[ $VIDEO_DURATION -lt 10 || $VIDEO_DURATION -gt 3600 ]]; then
    print_error "Duration must be between 10 and 3600 seconds"
    exit 1
fi

# Run main function
main