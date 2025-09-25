# Claude Code Configuration

## Project Overview
RTX 4090 Dual-NVENC Concurrent Stream Test Suite

## Key Technical Specs (from test-plan.md)
- **Target**: 100 concurrent streams (50 per NVENC encoder)
- **Architecture**: Dual-process concurrent (Process-1: NVENC #1, Process-2: NVENC #2)
- **Input**: 1920x1080@30fps → **Output**: 1280x720@30fps
- **Bitrate**: 2M CBR per stream
- **HLS**: 6-second segments, event playlist
- **Memory**: ~170MB per stream, ~17GB total VRAM usage

## Test Modes Available
```bash
# Test scaling options
conservative: 25 streams per NVENC (50 total)
standard:     50 streams per NVENC (100 total)  # Primary target
aggressive:   75 streams per NVENC (150 total)  # Stress test
maximum:     100 streams per NVENC (200 total)  # Absolute limits
```

## Critical FFmpeg Parameters
```bash
# Memory optimization (per test-plan.md)
-analyzeduration 10M -probesize 50M
-fflags +genpts+igndts -avoid_negative_ts make_zero
-hwaccel cuda -hwaccel_device 0 -hwaccel_output_format cuda
-threads 1 -thread_queue_size 512
-max_muxing_queue_size 1024

# NVENC encoding (720p30 optimized)
-c:v h264_nvenc -preset p4 -rc cbr
-b:v 2M -maxrate 2M -bufsize 4M -r 30
```

## Audio Handling Note
**IMPORTANT**: Current FFmpeg commands only process video streams (no audio mapping).
- Video mapping: `-map "[v0]", "[v1]", etc.`
- No audio streams included (audio is dropped)
- If audio needed: add `-map a` and `-c:a aac` parameters

## Success Criteria (from test-plan.md)
- **Concurrent Capacity**: ≥95% stream success rate for 100 streams
- **Performance**: ≥1x realtime encoding speed
- **Resources**: <20GB VRAM usage (24GB available)
- **Temperature**: <85°C GPU temp
- **Error Rate**: <1% stream failures
- **NVENC Balance**: ~50% load per encoder

## Lint/Typecheck Commands
```bash
# Bash script linting (if shellcheck is available)
shellcheck *.sh

# Python code formatting and linting
python -m py_compile *.py
```

## Git Workflow
- Always commit changes after modifications
- Push commits to track progress
- Use descriptive commit messages

## Test Commands
```bash
# Full workflow (from test-plan.md)
./setup.sh                        # Environment + FFmpeg installation
./create-test-videos.sh           # Generate 100+ input videos
./test-dual-nvenc.sh standard     # Run 100 concurrent streams test
./monitor-concurrent.py           # Real-time GPU monitoring (separate terminal)
./analyze-results.py              # Performance analysis with grading
./cleanup.sh                      # System cleanup

# Test different scales
./test-dual-nvenc.sh conservative  # 50 total streams
./test-dual-nvenc.sh aggressive    # 150 total streams
./test-dual-nvenc.sh maximum       # 200 total streams
```

## Directory Structure (from test-plan.md)
```
output/
├── nvenc1/          # Process-1 outputs (streams 001-050)
├── nvenc2/          # Process-2 outputs (streams 051-100)
└── logs/            # Process logs and monitoring data
```

## Resource Monitoring Thresholds
```bash
# Warning levels
VRAM_WARNING=18GB    # 75% usage
TEMP_WARNING=80°C    # GPU temperature
CPU_WARNING=80%      # CPU utilization

# Critical levels (test abort)
VRAM_CRITICAL=20GB   # 83% usage
TEMP_CRITICAL=85°C   # GPU temperature
CPU_CRITICAL=95%     # CPU utilization
```

## Architecture Notes
- **True Concurrency**: All 50 streams per process start simultaneously (no gradual startup)
- **Dual NVENC**: Each process targets different NVENC encoder
- **Memory Per Stream**: ~170MB (decode + scale + encode + HLS buffers)
- **RTX 4090 Capacity**: 100-120 streams theoretical max per conversation history