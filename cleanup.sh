#!/bin/bash

# RTX 4090 Concurrent Stream Test - Cleanup Script
# Cleans up test artifacts, processes, and resets system state

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[CLEANUP]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Configuration
FORCE_CLEANUP=false
KEEP_INPUTS=false
KEEP_LOGS=false
KEEP_OUTPUTS=false

show_help() {
    cat << EOF
RTX 4090 Test Cleanup Script
============================

Usage: $0 [OPTIONS]

OPTIONS:
  -f, --force           Force cleanup without confirmation
  --keep-inputs         Keep input video files
  --keep-logs           Keep log files
  --keep-outputs        Keep output HLS files
  --reset-gpu           Reset GPU state after cleanup
  -h, --help            Show this help

CLEANUP OPERATIONS:
  1. Kill running FFmpeg processes
  2. Stop monitoring processes
  3. Reset GPU state
  4. Clean output directories
  5. Clean log files
  6. Clean input files (optional)
  7. Remove temporary files

EXAMPLES:
  $0                    # Interactive cleanup
  $0 --force            # Force cleanup everything
  $0 --keep-inputs      # Keep input videos
  $0 --keep-logs --keep-outputs  # Keep logs and outputs

SAFETY:
  - Interactive mode asks for confirmation
  - Force mode skips confirmations
  - Keep flags preserve specific data
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE_CLEANUP=true
            shift
            ;;
        --keep-inputs)
            KEEP_INPUTS=true
            shift
            ;;
        --keep-logs)
            KEEP_LOGS=true
            shift
            ;;
        --keep-outputs)
            KEEP_OUTPUTS=true
            shift
            ;;
        --reset-gpu)
            RESET_GPU=true
            shift
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

confirm_action() {
    local message="$1"

    if [[ "$FORCE_CLEANUP" == "true" ]]; then
        return 0
    fi

    echo -e "${YELLOW}$message${NC}"
    read -p "Continue? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 1
    fi
    return 0
}

kill_ffmpeg_processes() {
    print_status "Checking for running FFmpeg processes..."

    # Find FFmpeg processes with NVENC
    local ffmpeg_pids=$(pgrep -f "ffmpeg.*nvenc" 2>/dev/null || true)

    if [[ -n "$ffmpeg_pids" ]]; then
        print_warning "Found FFmpeg NVENC processes: $ffmpeg_pids"

        if confirm_action "Kill running FFmpeg processes?"; then
            # Try graceful termination first
            for pid in $ffmpeg_pids; do
                print_status "Sending SIGTERM to FFmpeg process $pid"
                kill -TERM "$pid" 2>/dev/null || true
            done

            # Wait a moment for graceful shutdown
            sleep 3

            # Force kill if still running
            local remaining_pids=$(pgrep -f "ffmpeg.*nvenc" 2>/dev/null || true)
            if [[ -n "$remaining_pids" ]]; then
                print_warning "Force killing remaining processes: $remaining_pids"
                for pid in $remaining_pids; do
                    kill -KILL "$pid" 2>/dev/null || true
                done
            fi

            print_status "FFmpeg processes terminated"
        fi
    else
        print_info "No running FFmpeg processes found"
    fi
}

kill_monitoring_processes() {
    print_status "Checking for monitoring processes..."

    # Find Python monitoring scripts
    local monitor_pids=$(pgrep -f "monitor.*concurrent" 2>/dev/null || true)

    if [[ -n "$monitor_pids" ]]; then
        print_warning "Found monitoring processes: $monitor_pids"

        if confirm_action "Kill monitoring processes?"; then
            for pid in $monitor_pids; do
                print_status "Terminating monitoring process $pid"
                kill -TERM "$pid" 2>/dev/null || true
            done
            sleep 2
            print_status "Monitoring processes terminated"
        fi
    else
        print_info "No monitoring processes found"
    fi

    # Also check for nvidia-smi monitoring
    local nvidia_pids=$(pgrep -f "nvidia-smi.*dmon" 2>/dev/null || true)
    if [[ -n "$nvidia_pids" ]]; then
        print_warning "Found nvidia-smi monitoring: $nvidia_pids"
        for pid in $nvidia_pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
    fi
}

reset_gpu_state() {
    print_status "Checking GPU state..."

    if command -v nvidia-smi &> /dev/null; then
        # Show current GPU utilization
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo "unknown")
        local mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "unknown")

        print_info "Current GPU utilization: ${gpu_util}%"
        print_info "Current VRAM usage: ${mem_used}MB"

        if confirm_action "Reset GPU state?"; then
            print_status "Resetting GPU..."
            nvidia-smi -r 2>/dev/null || print_warning "GPU reset may require root privileges"
            sleep 2
            print_status "GPU reset completed"
        fi
    else
        print_warning "nvidia-smi not available, skipping GPU reset"
    fi
}

clean_output_files() {
    if [[ "$KEEP_OUTPUTS" == "true" ]]; then
        print_info "Keeping output files (--keep-outputs specified)"
        return
    fi

    print_status "Checking output files..."

    local output_dirs=("./output/nvenc1" "./output/nvenc2" "./output")
    local total_size=0
    local file_count=0

    # Calculate total size
    for dir in "${output_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local dir_size=$(du -sb "$dir" 2>/dev/null | cut -f1 || echo "0")
            total_size=$((total_size + dir_size))
            local dir_files=$(find "$dir" -type f | wc -l 2>/dev/null || echo "0")
            file_count=$((file_count + dir_files))
        fi
    done

    if [[ $total_size -gt 0 ]]; then
        local size_mb=$((total_size / 1024 / 1024))
        print_warning "Found output files: ${file_count} files, ${size_mb}MB"

        if confirm_action "Delete all output files?"; then
            for dir in "${output_dirs[@]}"; do
                if [[ -d "$dir" ]]; then
                    print_status "Cleaning $dir..."
                    rm -rf "$dir"
                fi
            done
            print_status "Output files cleaned"
        fi
    else
        print_info "No output files found"
    fi
}

clean_log_files() {
    if [[ "$KEEP_LOGS" == "true" ]]; then
        print_info "Keeping log files (--keep-logs specified)"
        return
    fi

    print_status "Checking log files..."

    local log_dir="./logs"

    if [[ -d "$log_dir" ]]; then
        local log_count=$(find "$log_dir" -type f | wc -l 2>/dev/null || echo "0")
        local log_size=$(du -sb "$log_dir" 2>/dev/null | cut -f1 || echo "0")
        local size_mb=$((log_size / 1024 / 1024))

        if [[ $log_count -gt 0 ]]; then
            print_warning "Found log files: ${log_count} files, ${size_mb}MB"

            if confirm_action "Delete log files?"; then
                rm -rf "$log_dir"
                print_status "Log files cleaned"
            fi
        else
            print_info "No log files found"
        fi
    else
        print_info "No log directory found"
    fi
}

clean_input_files() {
    if [[ "$KEEP_INPUTS" == "true" ]]; then
        print_info "Keeping input files (--keep-inputs specified)"
        return
    fi

    print_status "Checking input files..."

    local input_dir="./input"

    if [[ -d "$input_dir" ]]; then
        local input_count=$(find "$input_dir" -name "test_video_*.mp4" | wc -l 2>/dev/null || echo "0")
        local input_size=$(du -sb "$input_dir" 2>/dev/null | cut -f1 || echo "0")
        local size_mb=$((input_size / 1024 / 1024))

        if [[ $input_count -gt 0 ]]; then
            print_warning "Found input files: ${input_count} test videos, ${size_mb}MB"

            if confirm_action "Delete input test videos?"; then
                find "$input_dir" -name "test_video_*.mp4" -delete
                # Remove directory if empty
                rmdir "$input_dir" 2>/dev/null || true
                print_status "Input test videos cleaned"
            fi
        else
            print_info "No input test videos found"
        fi
    else
        print_info "No input directory found"
    fi
}

clean_temp_files() {
    print_status "Checking for temporary files..."

    # Common temp file patterns
    local temp_patterns=(
        "./core.*"
        "./*.tmp"
        "./*.temp"
        "./ffmpeg*.log"
        "./stream_*.log"
        "./.DS_Store"
    )

    local temp_found=false

    for pattern in "${temp_patterns[@]}"; do
        if ls $pattern 2>/dev/null | head -1 > /dev/null; then
            temp_found=true
            break
        fi
    done

    if [[ "$temp_found" == "true" ]]; then
        if confirm_action "Delete temporary files?"; then
            for pattern in "${temp_patterns[@]}"; do
                rm -f $pattern 2>/dev/null || true
            done
            print_status "Temporary files cleaned"
        fi
    else
        print_info "No temporary files found"
    fi
}

show_cleanup_summary() {
    print_status "Cleanup Summary"
    echo "==============="

    # Check remaining files
    local remaining_outputs=0
    local remaining_logs=0
    local remaining_inputs=0

    if [[ -d "./output" ]]; then
        remaining_outputs=$(find "./output" -type f 2>/dev/null | wc -l || echo "0")
    fi

    if [[ -d "./logs" ]]; then
        remaining_logs=$(find "./logs" -type f 2>/dev/null | wc -l || echo "0")
    fi

    if [[ -d "./input" ]]; then
        remaining_inputs=$(find "./input" -name "test_video_*.mp4" 2>/dev/null | wc -l || echo "0")
    fi

    echo "Remaining files:"
    echo "  - Outputs: $remaining_outputs files"
    echo "  - Logs: $remaining_logs files"
    echo "  - Inputs: $remaining_inputs test videos"

    # Check running processes
    local ffmpeg_procs=$(pgrep -f "ffmpeg.*nvenc" 2>/dev/null | wc -l || echo "0")
    local monitor_procs=$(pgrep -f "monitor.*concurrent" 2>/dev/null | wc -l || echo "0")

    echo "Running processes:"
    echo "  - FFmpeg: $ffmpeg_procs processes"
    echo "  - Monitoring: $monitor_procs processes"

    # GPU status
    if command -v nvidia-smi &> /dev/null; then
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo "unknown")
        local mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "unknown")

        echo "GPU status:"
        echo "  - Utilization: ${gpu_util}%"
        echo "  - VRAM used: ${mem_used}MB"
    fi
}

main() {
    print_status "RTX 4090 Test Cleanup Starting..."

    if [[ "$FORCE_CLEANUP" == "true" ]]; then
        print_info "Force mode enabled - no confirmations"
    fi

    # Step 1: Kill processes
    kill_ffmpeg_processes
    kill_monitoring_processes

    # Step 2: Reset GPU
    reset_gpu_state

    # Step 3: Clean files
    clean_output_files
    clean_log_files
    clean_input_files
    clean_temp_files

    # Step 4: Summary
    echo ""
    show_cleanup_summary

    print_status "Cleanup completed!"
    print_info "System should be ready for new tests"
}

# Trap to ensure cleanup on script exit
cleanup_on_exit() {
    print_info "Cleanup script interrupted"
}
trap cleanup_on_exit EXIT

# Run main function
main