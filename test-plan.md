# RTX 4090 Dual-NVENC Concurrent Stream Test Plan

## Proje Hedefi
RTX 4090'ın 2 NVENC encoder'ını kullanarak her encoder için 50 adet (toplam 100) statik video dosyasını aynı anda HLS formatına dönüştürmek ve maksimum concurrent stream kapasitesini test etmek.

## Conversation History'den Çıkarılan Teknik Bilgiler

### RTX 4090 NVENC Özellikleri
- **Dual NVENC Encoder:** 2 adet 8th generation NVENC
- **Teorik Kapasite:** Her NVENC için 50-60 stream (1080p→720p transcoding)
- **Toplam Beklenen Kapasite:** 100-120 concurrent stream
- **Test Hedefi:** Her NVENC için 50 stream = 100 total stream

### Mimari Yaklaşım (Conversation History'den)
```yaml
RTX 4090 Resource Allocation:
├── NVENC Stream #1: 50 input (process-1)
├── NVENC Stream #2: 50 input (process-2)
├── VRAM Allocation: 12GB NVENC buffers + 4GB system buffers
└── Total: 100 concurrent streams
```

## Test Mimarisi

### 1. Dual-Process Architecture

#### Process-1 (NVENC #1)
- **Input:** 50 adet statik video dosyası (stream 001-050)
- **NVENC ID:** 0
- **GPU Device:** 0
- **Output:** 50 adet HLS playlist + TS segment dosyaları

#### Process-2 (NVENC #2)
- **Input:** 50 adet statik video dosyası (stream 051-100)
- **NVENC ID:** 1 (manuel olarak belirtilecek)
- **GPU Device:** 0
- **Output:** 50 adet HLS playlist + TS segment dosyaları

### 2. Configurable Stream Control

#### Script Configuration Variables:
```bash
# Configurable Parameters
STREAMS_PER_NVENC=50          # Her NVENC encoder için stream sayısı
TOTAL_NVENC_ENCODERS=2        # RTX 4090'da 2 NVENC
TOTAL_STREAMS=$((STREAMS_PER_NVENC * TOTAL_NVENC_ENCODERS))  # 100 total

# Test Scaling Options
TEST_MODES=(
    "conservative:25"   # Her NVENC için 25 stream (50 total)
    "standard:50"       # Her NVENC için 50 stream (100 total)
    "aggressive:75"     # Her NVENC için 75 stream (150 total)
    "maximum:100"       # Her NVENC için 100 stream (200 total)
)
```

#### NVENC Encoder Control:
```bash
# NVENC Selection Functions
select_nvenc_encoder() {
    local process_id=$1
    case $process_id in
        1) echo "0" ;;  # First NVENC
        2) echo "1" ;;  # Second NVENC
        *) echo "0" ;;  # Fallback
    esac
}

# Dynamic Stream Distribution
calculate_stream_range() {
    local nvenc_id=$1
    local streams_per_nvenc=$2

    local start_stream=$(( (nvenc_id - 1) * streams_per_nvenc + 1 ))
    local end_stream=$(( nvenc_id * streams_per_nvenc ))

    echo "${start_stream}:${end_stream}"
}
```

### 3. FFmpeg Komut Yapısı

#### Process-1 Optimized Command (Stream 001-050):
```bash
ffmpeg \
  -analyzeduration 10M -probesize 50M \
  -fflags +genpts+igndts -avoid_negative_ts make_zero \
  -hwaccel cuda -hwaccel_device 0 -hwaccel_output_format cuda \
  -threads 1 -thread_queue_size 512 \
  -i input_001.mp4 -i input_002.mp4 ... -i input_050.mp4 \
  -filter_complex "[0:v]scale_cuda=1280:720:force_original_aspect_ratio=decrease,fps=30[v0];[1:v]scale_cuda=1280:720:force_original_aspect_ratio=decrease,fps=30[v1];...;[49:v]scale_cuda=1280:720:force_original_aspect_ratio=decrease,fps=30[v49]" \
  -map "[v0]" -c:v h264_nvenc -preset p4 -rc cbr \
    -b:v 2M -maxrate 2M -bufsize 4M -r 30 \
    -max_muxing_queue_size 1024 \
    -f hls -hls_time 6 -hls_playlist_type event \
    -hls_segment_filename "output/nvenc1/stream001/segment_%03d.ts" \
    "output/nvenc1/stream001/playlist.m3u8" \
  -map "[v1]" -c:v h264_nvenc -preset p4 -rc cbr \
    -b:v 2M -maxrate 2M -bufsize 4M -r 30 \
    -max_muxing_queue_size 1024 \
    -f hls -hls_time 6 -hls_playlist_type event \
    -hls_segment_filename "output/nvenc1/stream002/segment_%03d.ts" \
    "output/nvenc1/stream002/playlist.m3u8" \
  ... (50 output mappings with same parameters)
```

#### Process-2 Benzer Yapı (Stream 051-100):
- Stream 051-100 arası input'lar
- Aynı encoder parametreleri: **720p @ 30fps**
- Output directory: `output/nvenc2/stream051-100/`
- Bitrate: **2M CBR** (720p için optimize)

#### FFmpeg Parameters Explanation:
```bash
# Input Optimization Parameters
-analyzeduration 10M                   # Max analysis time (10 seconds)
-probesize 50M                         # Stream analysis data size (50MB)
-fflags +genpts+igndts                 # Generate PTS, ignore DTS
-avoid_negative_ts make_zero           # Handle timestamp issues

# Hardware Acceleration
-hwaccel cuda                          # CUDA hardware acceleration
-hwaccel_device 0                      # GPU device selection
-hwaccel_output_format cuda            # Keep decoded frames on GPU

# Video Processing Parameters
-filter_complex "scale_cuda=1280:720:  # GPU-based scaling to 720p
   force_original_aspect_ratio=decrease,
   fps=30"                             # Force 30fps output

# NVENC Encoder Settings
-c:v h264_nvenc                        # NVENC H.264 encoder
-preset p4                             # Fastest preset (lowest latency)
-rc cbr                                # Constant bitrate mode
-b:v 2M                                # 2 Mbps bitrate (720p30 optimal)
-maxrate 2M                            # Maximum bitrate cap
-bufsize 4M                            # VBV buffer size (2x bitrate)
-r 30                                  # Force 30fps framerate

# Memory and Performance Optimization
-threads 1                             # Single thread per stream
-thread_queue_size 512                 # Input thread queue size
-max_muxing_queue_size 1024           # Muxer queue size limit
```

#### NVENC Encoder Assignment (Critical):
```bash
# Process-1: Force use of first NVENC
export CUDA_VISIBLE_DEVICES=0
ffmpeg ... -init_hw_device cuda=gpu0:0 -filter_hw_device gpu0 ...

# Process-2: Force use of second NVENC (manual selection needed)
# Note: FFmpeg doesn't directly expose NVENC selection
# Workaround: Use different CUDA contexts or process affinity
export CUDA_VISIBLE_DEVICES=0
ffmpeg ... -init_hw_device cuda=gpu0:0 -filter_hw_device gpu0 ...
```

### 3. Input Video Hazırlığı

#### Test Video Özellikleri:
- **Format:** MP4 (H.264)
- **Resolution:** 1920x1080
- **Frame Rate:** 30fps
- **Duration:** 120 saniye (test için yeterli)
- **Codec:** libx264 (CPU encoded, hardware decode test için)

#### Video Oluşturma:
```bash
# 100 adet test videosu oluştur (001-100)
for i in {001..100}; do
  ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=120" \
         -f lavfi -i "sine=frequency=$(( (10#$i-1)*50 + 1000 )):sample_rate=48000:duration=120" \
         -c:v libx264 -preset fast -crf 23 \
         -c:a aac -b:a 128k \
         -pix_fmt yuv420p \
         "input/test_video_$i.mp4"
done
```

#### Configurable Input Creation:
```bash
create_test_videos() {
    local total_streams=$1
    local video_duration=${2:-120}

    echo "Creating $total_streams test videos..."

    for i in $(seq -f "%03g" 1 $total_streams); do
        if [ ! -f "input/test_video_$i.mp4" ]; then
            ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=$video_duration" \
                   -f lavfi -i "sine=frequency=$(( (10#$i-1)*50 + 1000 )):sample_rate=48000:duration=$video_duration" \
                   -c:v libx264 -preset fast -crf 23 \
                   -c:a aac -b:a 128k \
                   -pix_fmt yuv420p \
                   "input/test_video_$i.mp4" &> /dev/null
        fi

        # Progress indicator
        if [ $((10#$i % 10)) -eq 0 ]; then
            echo "Created $i/$total_streams videos..."
        fi
    done
}
```

### 4. HLS Output Yapısı

#### Dizin Organizasyonu:
```
output/
├── nvenc1/                    # Process-1 outputs (NVENC #1)
│   ├── stream001/
│   │   ├── playlist.m3u8
│   │   ├── segment_000.ts
│   │   ├── segment_001.ts
│   │   └── ...
│   ├── stream002/
│   │   ├── playlist.m3u8
│   │   └── segment_*.ts
│   ├── ...
│   └── stream050/
│       ├── playlist.m3u8
│       └── segment_*.ts
├── nvenc2/                    # Process-2 outputs (NVENC #2)
│   ├── stream051/
│   │   ├── playlist.m3u8
│   │   └── segment_*.ts
│   ├── stream052/
│   │   ├── playlist.m3u8
│   │   └── segment_*.ts
│   ├── ...
│   └── stream100/
│       ├── playlist.m3u8
│       └── segment_*.ts
└── logs/
    ├── nvenc1_process.log
    ├── nvenc2_process.log
    └── monitoring.log
```

#### HLS Parametreleri:
- **Segment Duration:** 6 saniye
- **Playlist Type:** Event (finite content)
- **Target Bitrate:** 2 Mbps
- **Output Resolution:** 1280x720 (720p)
- **Output Frame Rate:** 30fps (matching input)
- **Codec:** H.264 (NVENC)

### 5. Monitoring ve Metrikler

#### GPU Metrikleri:
- NVENC utilization per encoder
- VRAM usage
- GPU temperature
- Power consumption
- Encoder session count

#### Performance Metrikleri:
- Encoding speed (realtime multiple)
- Frame drops
- Error rate
- CPU usage
- Memory usage

#### Test Başarı Kriterleri:
- **100 stream success:** %95+ başarı oranı (each NVENC: 50 streams)
- **Realtime encoding:** En az 1x realtime speed
- **VRAM usage:** <20GB (24GB VRAM'den)
- **Temperature:** <85°C
- **Error rate:** <%1
- **NVENC Balance:** Her encoder ~50% yük dağılımı

### 6. Script Yapısı

#### Ana Test Script (test-dual-nvenc.sh):
```bash
#!/bin/bash

# Configurable Parameters
STREAMS_PER_NVENC=${STREAMS_PER_NVENC:-50}     # Default: 50 per NVENC
TOTAL_NVENC_ENCODERS=2                         # RTX 4090 has 2 NVENC
TOTAL_STREAMS=$((STREAMS_PER_NVENC * TOTAL_NVENC_ENCODERS))

# Directories
INPUT_DIR="./input"
OUTPUT_DIR="./output"
LOG_DIR="./logs"

# Test Mode Selection
TEST_MODE=${1:-"standard"}    # conservative|standard|aggressive|maximum

case $TEST_MODE in
    "conservative") STREAMS_PER_NVENC=25 ;;    # 50 total
    "standard")     STREAMS_PER_NVENC=50 ;;    # 100 total
    "aggressive")   STREAMS_PER_NVENC=75 ;;    # 150 total
    "maximum")      STREAMS_PER_NVENC=100 ;;   # 200 total
    *) echo "Usage: $0 [conservative|standard|aggressive|maximum]"; exit 1 ;;
esac

# Recalculate total after mode selection
TOTAL_STREAMS=$((STREAMS_PER_NVENC * TOTAL_NVENC_ENCODERS))

echo "Test Mode: $TEST_MODE"
echo "Streams per NVENC: $STREAMS_PER_NVENC"
echo "Total Streams: $TOTAL_STREAMS"

# Phase 1: Input preparation
prepare_input_videos() {
    create_test_videos $TOTAL_STREAMS
}

# Phase 2: Concurrent dual process launch
launch_nvenc1_process() {
    # Streams 1 to STREAMS_PER_NVENC, NVENC #1 (concurrent)
    local start_stream=1
    local end_stream=$STREAMS_PER_NVENC
    launch_concurrent_ffmpeg_process 1 $start_stream $end_stream
}

launch_nvenc2_process() {
    # Streams (STREAMS_PER_NVENC+1) to TOTAL_STREAMS, NVENC #2 (concurrent)
    local start_stream=$((STREAMS_PER_NVENC + 1))
    local end_stream=$TOTAL_STREAMS
    launch_concurrent_ffmpeg_process 2 $start_stream $end_stream
}

# Phase 3: Monitoring
monitor_performance() {
    # Monitor both processes and GPU utilization
    monitor_dual_nvenc_usage
}

# Phase 4: Analysis
analyze_results() {
    # Analyze per-NVENC performance
    analyze_nvenc_performance
}
```

#### Command Line Usage:
```bash
# Test different modes
./test-dual-nvenc.sh conservative    # 50 total streams (25 each)
./test-dual-nvenc.sh standard        # 100 total streams (50 each)
./test-dual-nvenc.sh aggressive      # 150 total streams (75 each)
./test-dual-nvenc.sh maximum         # 200 total streams (100 each)

# Environment variable override
STREAMS_PER_NVENC=40 ./test-dual-nvenc.sh standard  # Custom: 80 total
```

#### Yardımcı Scriptler:
- `create-test-videos.sh`: Input video oluşturma
- `monitor-gpu.py`: Real-time GPU monitoring
- `analyze-results.py`: Test sonuç analizi
- `cleanup.sh`: Test sonrası temizlik

### 7. Memory ve Performance Constraints

#### System Resource Limits:
```bash
# Per-Stream Memory Calculation (720p30)
INPUT_BUFFER=50M      # analyzeduration + probesize
DECODE_BUFFER=32M     # CUDA decode buffer per stream
SCALE_BUFFER=16M      # GPU scaling buffer
ENCODE_BUFFER=64M     # NVENC encode buffer
HLS_BUFFER=8M         # HLS muxer buffer
TOTAL_PER_STREAM=170M # ~170MB per stream

# 50 Streams per Process
PROCESS_MEMORY=8.5GB  # 50 × 170MB
DUAL_PROCESS_TOTAL=17GB # Both processes

# RTX 4090 VRAM (24GB)
SYSTEM_OVERHEAD=2GB   # OS + drivers
AVAILABLE_VRAM=22GB   # Safe limit
MEMORY_SAFETY_MARGIN=5GB # Emergency buffer
```

#### FFmpeg Resource Constraints:
```bash
# Memory Limits per Process
ulimit -v 10485760    # 10GB virtual memory limit
ulimit -m 8388608     # 8GB resident memory limit

# File Descriptor Limits
ulimit -n 4096        # 4K file descriptors (50 inputs + outputs)

# Process Limits
ulimit -u 2048        # Max user processes
```

#### System Monitoring Thresholds:
```bash
# Warning Levels
VRAM_WARNING=18GB     # 75% VRAM usage
CPU_WARNING=80%       # CPU utilization
TEMP_WARNING=80C      # GPU temperature

# Critical Levels (abort test)
VRAM_CRITICAL=20GB    # 83% VRAM usage
CPU_CRITICAL=95%      # CPU utilization
TEMP_CRITICAL=85C     # GPU temperature
MEMORY_CRITICAL=90%   # System RAM usage
```

### 8. Beklenen Zorluklar ve Çözümler

#### Problem 1: NVENC Session Limit
- **Durum:** Consumer GPU'da 8 session limit
- **Çözüm:** FFmpeg process'lerin aynı anda başlatılması, session pooling

#### Problem 2: Memory Exhaustion
- **Durum:** 100 stream için ~17GB VRAM + 16GB RAM
- **Çözüm:** Buffer size optimization, memory monitoring

#### Problem 3: Buffer Overflow
- **Durum:** HLS segment writing bottleneck
- **Çözüm:** Increased muxing queue, SSD storage

#### Problem 4: Process Synchronization
- **Durum:** İki process'in eşzamanlı başlatılması ve monitoring
- **Çözüm:** Parallel process launch, real-time health monitoring

### 8. Test Senaryoları

#### Senaryo 1: Conservative Test (50 Total)
- **Input:** 50 x 1080p30 (25 per NVENC) → **Output:** 50 x 720p30
- **Bitrate:** 2M CBR per stream
- **Duration:** 60 saniye
- **Hedef:** Stable baseline capacity test

#### Senaryo 2: Standard Test (100 Total)
- **Input:** 100 x 1080p30 (50 per NVENC) → **Output:** 100 x 720p30
- **Bitrate:** 2M CBR per stream
- **Duration:** 60 saniye
- **Hedef:** Target capacity test

#### Senaryo 3: Aggressive Test (150 Total)
- **Input:** 150 x 1080p30 (75 per NVENC) → **Output:** 150 x 720p30
- **Bitrate:** 2M CBR per stream
- **Duration:** 60 saniye
- **Hedef:** Push beyond safe limits

#### Senaryo 4: Maximum Test (200 Total)
- **Input:** 200 x 1080p30 (100 per NVENC) → **Output:** 200 x 720p30
- **Bitrate:** 2M CBR per stream
- **Duration:** 60 saniye
- **Hedef:** Absolute maximum capacity

#### Senaryo 5: Quality Stress Test (Same Resolution)
- **Input:** 100 x 1080p30 → **Output:** 100 x 1080p30 (no downscale)
- **Bitrate:** 4M CBR per stream (higher for 1080p)
- **Duration:** 60 saniye
- **Hedef:** Maximum quality per stream

#### Senaryo 6: Lower Bitrate Test
- **Input:** 100 x 1080p30 → **Output:** 100 x 720p30
- **Bitrate:** 1M CBR per stream (bandwidth test)
- **Duration:** 60 saniye
- **Hedef:** Lower bitrate efficiency test

#### Senaryo 7: Endurance Test
- **Input:** 100 x 1080p30 → **Output:** 100 x 720p30
- **Bitrate:** 2M CBR per stream
- **Duration:** 10 dakika
- **Hedef:** Thermal throttling and stability

#### Senaryo 8: Progressive Scaling
- **Stages:** 25→50→75→100→125→150 streams
- **Output:** Always 720p30 @ 2M CBR
- **Duration:** Her aşama 2 dakika
- **Hedef:** Failure point detection

### 9. Sonuç Değerlendirme

#### Başarı Metrikleri:
1. **Concurrent Capacity:** Maksimum stable stream sayısı
2. **Quality Assessment:** Output video kalitesi
3. **Efficiency:** Realtime encoding multiple
4. **Reliability:** Hata oranı ve stability
5. **Resource Usage:** CPU, GPU, RAM optimizasyon

#### Raporlama:
- **Real-time Dashboard:** GPU status, stream health
- **Final Report:** Capacity, performance, recommendations
- **Logs:** Detaylı debug ve error logs
- **Benchmark Data:** JSON format results

## Concurrent Testing Approach

### **True Concurrency:**
- **Tüm 50 stream aynı FFmpeg process'te**
- **Aynı anda memory allocation**
- **Gerçek NVENC capacity test**
- **No gradual startup - pure concurrent load**

### **Dual Process Concurrency:**
```bash
# Process-1: 50 concurrent streams → NVENC #1
# Process-2: 50 concurrent streams → NVENC #2
# Launch: Parallel (aynı anda başlat)
# Total: 100 concurrent streams
```

## Sonraki Adımlar

1. **Input Video Creation Script** - 100 test videosu hazırlama
2. **Dual Concurrent FFmpeg Script** - True concurrent test
3. **Real-time Monitoring System** - NVENC utilization tracking
4. **Analysis Tools** - Concurrent performance analizi
5. **Stress Testing** - Maximum capacity determination

Bu plan RTX 4090'ın dual NVENC architecture'ında gerçek concurrent stream capacity'sini test etmek için tasarlanmıştır.