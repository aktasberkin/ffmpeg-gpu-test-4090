#!/bin/bash

# RTX 4090 Concurrent Stream Test - Setup Script
# Initializes directory structure and validates environment

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[SETUP]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_header() { echo -e "${MAGENTA}[HEADER]${NC} $1"; }

show_help() {
    cat << EOF
RTX 4090 Test Environment Setup
===============================

Usage: $0 [OPTIONS]

OPTIONS:
  --max-streams NUM     Maximum streams to prepare for (default: 200)
  --check-only         Only validate environment, don't create directories
  --force              Force setup even if directories exist
  --auto-install       Automatically install missing dependencies
  -h, --help           Show this help

SETUP OPERATIONS:
  1. Validate system requirements
  2. Check FFmpeg and NVIDIA drivers
  3. Create directory structure
  4. Set appropriate permissions
  5. Generate usage examples
  6. Create environment info file

EXAMPLES:
  $0                   # Standard setup for up to 200 streams
  $0 --max-streams 100 # Setup for up to 100 streams
  $0 --check-only      # Just validate environment
EOF
}

# Default configuration
MAX_STREAMS=200
CHECK_ONLY=false
FORCE_SETUP=false
AUTO_INSTALL=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-streams)
            MAX_STREAMS="$2"
            shift 2
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --force)
            FORCE_SETUP=true
            shift
            ;;
        --auto-install)
            AUTO_INSTALL=true
            FORCE_SETUP=true  # Auto-install implies force
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

# Validate MAX_STREAMS
if [[ $MAX_STREAMS -lt 10 || $MAX_STREAMS -gt 1000 ]]; then
    print_error "MAX_STREAMS must be between 10 and 1000"
    exit 1
fi

print_header "RTX 4090 Concurrent Stream Test - Environment Setup"
print_info "Maximum streams: $MAX_STREAMS"
if [[ "$AUTO_INSTALL" == "true" ]]; then
    print_info "Auto-install mode: Will install missing dependencies automatically"
fi

check_system_requirements() {
    print_status "Checking system requirements..."

    local errors=0

    # Check operating system
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        print_info "✓ Linux system detected"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        print_info "✓ macOS system detected"
        print_warning "Note: NVIDIA GPU support limited on macOS"
    else
        print_error "✗ Unsupported operating system: $OSTYPE"
        ((errors++))
    fi

    # Check available disk space
    local available_kb=$(df . | tail -1 | awk '{print $4}')
    local required_kb=$((MAX_STREAMS * 25 * 1024))  # ~25MB per test video

    if [[ $available_kb -gt $required_kb ]]; then
        local available_gb=$((available_kb / 1024 / 1024))
        local required_gb=$((required_kb / 1024 / 1024))
        print_info "✓ Sufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
    else
        print_error "✗ Insufficient disk space"
        ((errors++))
    fi

    # Check memory (if available)
    if command -v free &> /dev/null; then
        local total_mem_kb=$(free | grep '^Mem:' | awk '{print $2}')
        local total_mem_gb=$((total_mem_kb / 1024 / 1024))

        if [[ $total_mem_gb -ge 16 ]]; then
            print_info "✓ Sufficient system RAM: ${total_mem_gb}GB"
        else
            print_warning "⚠ Limited system RAM: ${total_mem_gb}GB (16GB+ recommended)"
        fi
    fi

    return $errors
}

install_ffmpeg() {
    print_status "Installing FFmpeg with NVIDIA support..."

    local install_method=""
    local install_success=false

    # Detect OS and package manager
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt &> /dev/null; then
            install_method="apt"
        elif command -v yum &> /dev/null; then
            install_method="yum"
        elif command -v pacman &> /dev/null; then
            install_method="pacman"
        elif command -v snap &> /dev/null; then
            install_method="snap"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            install_method="brew"
        fi
    fi

    if [[ -z "$install_method" ]]; then
        print_error "No supported package manager found"
        print_info "Please install FFmpeg manually with NVIDIA support"
        return 1
    fi

    print_info "Using package manager: $install_method"

    case $install_method in
        "apt")
            print_status "Installing FFmpeg via apt..."
            if confirm_action "Install FFmpeg with: sudo apt update && sudo apt install -y ffmpeg"; then
                if sudo apt update && sudo apt install -y ffmpeg; then
                    install_success=true
                fi
            fi
            ;;
        "yum")
            print_status "Installing FFmpeg via yum..."
            if confirm_action "Install FFmpeg with: sudo yum install -y ffmpeg"; then
                # Try EPEL first
                sudo yum install -y epel-release 2>/dev/null || true
                if sudo yum install -y ffmpeg; then
                    install_success=true
                fi
            fi
            ;;
        "pacman")
            print_status "Installing FFmpeg via pacman..."
            if confirm_action "Install FFmpeg with: sudo pacman -S --noconfirm ffmpeg"; then
                if sudo pacman -S --noconfirm ffmpeg; then
                    install_success=true
                fi
            fi
            ;;
        "snap")
            print_status "Installing FFmpeg via snap..."
            if confirm_action "Install FFmpeg with: sudo snap install ffmpeg"; then
                if sudo snap install ffmpeg; then
                    install_success=true
                    # Add snap bin to PATH if not already there
                    if [[ ":$PATH:" != *":/snap/bin:"* ]]; then
                        export PATH="/snap/bin:$PATH"
                        print_info "Added /snap/bin to PATH"
                    fi
                fi
            fi
            ;;
        "brew")
            print_status "Installing FFmpeg via Homebrew..."
            if confirm_action "Install FFmpeg with: brew install ffmpeg"; then
                if brew install ffmpeg; then
                    install_success=true
                fi
            fi
            ;;
    esac

    if [[ "$install_success" == "true" ]]; then
        print_status "✓ FFmpeg installation completed"
        # Give system a moment to update PATH
        sleep 2
        return 0
    else
        print_error "✗ FFmpeg installation failed"
        return 1
    fi
}

install_ffmpeg_from_source() {
    print_warning "Installing FFmpeg from source with full NVIDIA support..."

    if ! confirm_action "This will compile FFmpeg from source (takes 10-30 minutes). Continue?"; then
        return 1
    fi

    local build_dir="/tmp/ffmpeg-build-$$"
    mkdir -p "$build_dir"
    cd "$build_dir"

    print_status "Installing build dependencies..."

    # Install build dependencies based on OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt &> /dev/null; then
            sudo apt update
            sudo apt install -y \
                build-essential pkg-config \
                nasm yasm \
                libx264-dev libx265-dev \
                libnuma-dev \
                git wget
        elif command -v yum &> /dev/null; then
            sudo yum groupinstall -y "Development Tools"
            sudo yum install -y \
                nasm yasm \
                x264-devel x265-devel \
                numactl-devel \
                git wget
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            brew install nasm pkg-config x264 x265
        fi
    fi

    # Download NVIDIA Video Codec SDK headers (if not already present)
    if [[ ! -d "/usr/local/include/ffnvcodec" ]]; then
        print_status "Installing NVIDIA Video Codec SDK headers..."
        git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git
        cd nv-codec-headers
        make && sudo make install
        cd ..
    fi

    # Download and compile FFmpeg
    print_status "Downloading FFmpeg source..."
    git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg-source
    cd ffmpeg-source

    print_status "Configuring FFmpeg build..."
    ./configure \
        --enable-nonfree \
        --enable-cuda-nvcc \
        --enable-libnpp \
        --enable-nvenc \
        --enable-nvdec \
        --enable-cuvid \
        --enable-libx264 \
        --enable-libx265 \
        --enable-gpl \
        --disable-static \
        --enable-shared \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64

    print_status "Compiling FFmpeg (this may take 15-30 minutes)..."
    make -j$(nproc)

    print_status "Installing FFmpeg..."
    sudo make install

    # Update library cache
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo ldconfig
    fi

    cd /
    rm -rf "$build_dir"

    print_status "✓ FFmpeg compiled and installed from source"
    return 0
}

check_ffmpeg() {
    print_status "Checking FFmpeg installation..."

    local ffmpeg_missing=false
    local nvenc_missing=false

    # Check if FFmpeg exists
    if ! command -v ffmpeg &> /dev/null; then
        print_error "✗ FFmpeg not found"
        ffmpeg_missing=true
    else
        local ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -n1)
        print_info "✓ FFmpeg found: $ffmpeg_version"

        # Check NVENC support
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
            print_info "✓ NVENC H.264 support available"
        else
            print_error "✗ NVENC H.264 support not found"
            nvenc_missing=true
        fi

        # Check additional codec support
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "hevc_nvenc"; then
            print_info "✓ NVENC H.265 support available"
        fi

        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_nvenc"; then
            print_info "✓ NVENC AV1 support available"
        fi
    fi

    # If FFmpeg is missing or lacks NVENC support, offer to install
    if [[ "$ffmpeg_missing" == "true" ]]; then
        print_warning "FFmpeg is not installed"

        local should_install=false
        if [[ "$AUTO_INSTALL" == "true" ]]; then
            print_info "Auto-install mode: Installing FFmpeg automatically..."
            should_install=true
        elif confirm_action "Install FFmpeg automatically?"; then
            should_install=true
        fi

        if [[ "$should_install" == "true" ]]; then
            if install_ffmpeg; then
                # Re-check after installation
                return $(check_ffmpeg)
            else
                print_error "Automatic installation failed"
                return 1
            fi
        else
            print_info "Manual installation required"
            return 1
        fi

    elif [[ "$nvenc_missing" == "true" ]]; then
        print_warning "FFmpeg lacks NVIDIA NVENC support"
        print_info "This may be due to:"
        print_info "  - FFmpeg not compiled with --enable-nvenc"
        print_info "  - Missing NVIDIA Video Codec SDK headers"
        print_info "  - Package repository FFmpeg without NVIDIA support"

        local should_compile=false
        if [[ "$AUTO_INSTALL" == "true" ]]; then
            print_info "Auto-install mode: Compiling FFmpeg with NVIDIA support..."
            should_compile=true
        elif confirm_action "Try to install FFmpeg with NVIDIA support from source?"; then
            should_compile=true
        fi

        if [[ "$should_compile" == "true" ]]; then
            if install_ffmpeg_from_source; then
                return $(check_ffmpeg)
            else
                print_error "Source compilation failed"
                return 1
            fi
        else
            print_warning "Continuing with limited functionality"
            return 1
        fi
    fi

    return 0
}

confirm_action() {
    local message="$1"

    if [[ "$FORCE_SETUP" == "true" ]]; then
        print_info "$message (auto-confirmed by --force)"
        return 0
    fi

    echo -e "${YELLOW}$message${NC}"
    read -p "Continue? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    fi
    return 1
}

check_nvidia_drivers() {
    print_status "Checking NVIDIA GPU and drivers..."

    if ! command -v nvidia-smi &> /dev/null; then
        print_error "✗ nvidia-smi not found"
        print_info "Install NVIDIA drivers:"
        print_info "  https://developer.nvidia.com/cuda-downloads"
        return 1
    fi

    # Get GPU information
    local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null)
    local driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)
    local cuda_version=$(nvidia-smi | grep "CUDA Version" | sed 's/.*CUDA Version: \([0-9.]*\).*/\1/' 2>/dev/null || echo "unknown")

    if [[ -n "$gpu_name" ]]; then
        print_info "✓ GPU detected: $gpu_name"
        print_info "✓ Driver version: $driver_version"
        print_info "✓ CUDA version: $cuda_version"

        # Check if it's RTX 4090
        if [[ "$gpu_name" == *"RTX 4090"* ]]; then
            print_info "✓ RTX 4090 detected - optimal for this test"
        else
            print_warning "⚠ Non-RTX 4090 GPU detected"
            print_warning "  Test results may not reflect RTX 4090 performance"
        fi

        # Check VRAM
        local total_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
        if [[ $total_vram -ge 20000 ]]; then
            print_info "✓ Sufficient VRAM: ${total_vram}MB"
        else
            print_warning "⚠ Limited VRAM: ${total_vram}MB (20GB+ recommended for high stream counts)"
        fi
    else
        print_error "✗ No NVIDIA GPU detected"
        return 1
    fi

    return 0
}

check_python_dependencies() {
    print_status "Checking Python dependencies..."

    if ! command -v python3 &> /dev/null; then
        print_error "✗ Python 3 not found"
        return 1
    fi

    local python_version=$(python3 --version 2>&1 | cut -d' ' -f2)
    print_info "✓ Python 3 found: $python_version"

    # Check required packages
    local required_packages=("psutil")
    local optional_packages=("matplotlib" "numpy" "pandas")

    for package in "${required_packages[@]}"; do
        if python3 -c "import $package" 2>/dev/null; then
            print_info "✓ Required package: $package"
        else
            print_error "✗ Missing required package: $package"
            print_info "Install with: pip3 install $package"
        fi
    done

    for package in "${optional_packages[@]}"; do
        if python3 -c "import $package" 2>/dev/null; then
            print_info "✓ Optional package: $package"
        else
            print_warning "⚠ Missing optional package: $package (for analysis plots)"
        fi
    done

    return 0
}

create_directory_structure() {
    print_status "Creating directory structure..."

    # Main directories
    local directories=(
        "input"
        "output/nvenc1"
        "output/nvenc2"
        "logs"
        "results"
        "scripts"
    )

    for dir in "${directories[@]}"; do
        if [[ -d "$dir" ]] && [[ "$FORCE_SETUP" != "true" ]]; then
            print_info "Directory exists: $dir"
        else
            mkdir -p "$dir"
            print_status "Created: $dir"
        fi
    done

    # Create stream subdirectories
    local streams_per_nvenc=$((MAX_STREAMS / 2))

    print_info "Creating stream directories for up to $MAX_STREAMS streams..."

    # NVENC1 stream directories
    for i in $(seq -f "%03g" 1 $streams_per_nvenc); do
        mkdir -p "output/nvenc1/stream$i"
    done

    # NVENC2 stream directories
    for i in $(seq -f "%03g" $((streams_per_nvenc + 1)) $MAX_STREAMS); do
        mkdir -p "output/nvenc2/stream$i"
    done

    print_status "Stream directories created: $MAX_STREAMS total"
}

set_permissions() {
    print_status "Setting permissions..."

    # Make all scripts executable
    local scripts=(
        "create-test-videos.sh"
        "test-dual-nvenc.sh"
        "monitor-concurrent.py"
        "build-ffmpeg-cmd.sh"
        "analyze-results.py"
        "cleanup.sh"
        "setup.sh"
    )

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            print_info "Made executable: $script"
        fi
    done

    # Set directory permissions
    chmod 755 input output logs results scripts 2>/dev/null || true
}

create_environment_info() {
    print_status "Creating environment information file..."

    local env_file="environment_info.txt"

    cat > "$env_file" << EOF
RTX 4090 Concurrent Stream Test - Environment Information
=========================================================
Generated: $(date)
Setup Script Version: 1.0

System Information:
------------------
OS: $(uname -s -r)
Architecture: $(uname -m)
Hostname: $(hostname)
User: $(whoami)
Working Directory: $(pwd)

Hardware Information:
-------------------
EOF

    # Add GPU information
    if command -v nvidia-smi &> /dev/null; then
        echo "GPU Information:" >> "$env_file"
        nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv >> "$env_file"
        echo "" >> "$env_file"
    fi

    # Add CPU information (Linux)
    if [[ -f "/proc/cpuinfo" ]]; then
        local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
        local cpu_cores=$(nproc)
        echo "CPU: $cpu_model" >> "$env_file"
        echo "CPU Cores: $cpu_cores" >> "$env_file"
    fi

    # Add memory information
    if command -v free &> /dev/null; then
        echo "Memory Information:" >> "$env_file"
        free -h >> "$env_file"
        echo "" >> "$env_file"
    fi

    # Add disk space
    echo "Disk Space:" >> "$env_file"
    df -h . >> "$env_file"
    echo "" >> "$env_file"

    # Add software versions
    cat >> "$env_file" << EOF

Software Versions:
-----------------
EOF

    if command -v ffmpeg &> /dev/null; then
        echo "FFmpeg: $(ffmpeg -version 2>/dev/null | head -1)" >> "$env_file"
    fi

    if command -v python3 &> /dev/null; then
        echo "Python: $(python3 --version)" >> "$env_file"
    fi

    # Add test configuration
    cat >> "$env_file" << EOF

Test Configuration:
------------------
Maximum Streams: $MAX_STREAMS
Streams per NVENC: $((MAX_STREAMS / 2))
Setup Date: $(date)
Setup User: $(whoami)

Directory Structure:
-------------------
EOF

    # List directory structure
    if command -v tree &> /dev/null; then
        tree -d -L 3 >> "$env_file"
    else
        find . -type d -maxdepth 3 | sort >> "$env_file"
    fi

    print_info "Environment info saved: $env_file"
}

create_usage_examples() {
    print_status "Creating usage examples..."

    local examples_file="USAGE_EXAMPLES.md"

    cat > "$examples_file" << EOF
# RTX 4090 Concurrent Stream Test - Usage Examples

## Quick Start

### 1. Create Test Videos
\`\`\`bash
# Create 100 test videos (default)
./create-test-videos.sh

# Create custom number of videos
./create-test-videos.sh 200 120  # 200 videos, 120s each
\`\`\`

### 2. Run Concurrent Stream Test
\`\`\`bash
# Standard test (100 total streams: 50 per NVENC)
./test-dual-nvenc.sh standard

# Conservative test (50 total streams: 25 per NVENC)
./test-dual-nvenc.sh conservative

# Aggressive test (150 total streams: 75 per NVENC)
./test-dual-nvenc.sh aggressive

# Maximum test (200 total streams: 100 per NVENC)
./test-dual-nvenc.sh maximum
\`\`\`

### 3. Monitor Performance (Optional)
\`\`\`bash
# Run monitoring in separate terminal
./monitor-concurrent.py -d 300  # Monitor for 5 minutes
\`\`\`

### 4. Analyze Results
\`\`\`bash
# Analyze test results and generate report
./analyze-results.py
\`\`\`

### 5. Clean Up
\`\`\`bash
# Interactive cleanup
./cleanup.sh

# Force cleanup everything
./cleanup.sh --force

# Keep specific files
./cleanup.sh --keep-inputs --keep-logs
\`\`\`

## Advanced Usage

### Custom FFmpeg Commands
\`\`\`bash
# Generate command for streams 1-50 (NVENC1)
./build-ffmpeg-cmd.sh -s 1 -e 50 --dry-run

# Generate command for streams 51-100 (NVENC2)
./build-ffmpeg-cmd.sh -s 51 -e 100 -o ./output/nvenc2 --dry-run

# Custom resolution and bitrate
./build-ffmpeg-cmd.sh -r 1920x1080 -b 4M --save-to-file custom_test.sh
\`\`\`

### Environment Validation
\`\`\`bash
# Check system requirements only
./setup.sh --check-only

# Setup for different stream count
./setup.sh --max-streams 150
\`\`\`

### Test Scenarios

#### Scenario 1: Baseline Capacity Test
\`\`\`bash
# Test basic concurrent capacity
./create-test-videos.sh 100
./test-dual-nvenc.sh standard
./analyze-results.py
\`\`\`

#### Scenario 2: Maximum Stress Test
\`\`\`bash
# Push RTX 4090 to limits
./create-test-videos.sh 200
./test-dual-nvenc.sh maximum
./analyze-results.py
\`\`\`

#### Scenario 3: Quality vs Quantity
\`\`\`bash
# Test with higher bitrate
STREAMS_PER_NVENC=25 ./test-dual-nvenc.sh standard
# Then analyze with custom resolution
./build-ffmpeg-cmd.sh -r 1920x1080 -b 6M --execute
\`\`\`

## Troubleshooting

### Common Issues
1. **NVENC session limit**: Use fewer concurrent streams
2. **Memory exhaustion**: Reduce stream count or video duration
3. **Permission errors**: Run \`chmod +x *.sh *.py\`
4. **Missing dependencies**: Run \`./setup.sh --check-only\`

### Performance Tips
- Use SSD storage for best I/O performance
- Ensure adequate cooling for sustained tests
- Monitor GPU temperature during long tests
- Close unnecessary applications before testing

## File Structure
\`\`\`
.
├── input/           # Test input videos
├── output/          # HLS output streams
│   ├── nvenc1/     # NVENC #1 outputs
│   └── nvenc2/     # NVENC #2 outputs
├── logs/           # Test and monitoring logs
├── results/        # Analysis results and plots
└── scripts/        # Generated script files
\`\`\`

## Environment Variables
\`\`\`bash
# Override default stream count
export STREAMS_PER_NVENC=40

# Custom test duration
export TEST_DURATION=300

# Custom directories
export INPUT_DIR="/path/to/inputs"
export OUTPUT_DIR="/path/to/outputs"
export LOG_DIR="/path/to/logs"
\`\`\`
EOF

    print_info "Usage examples saved: $examples_file"
}

show_setup_summary() {
    print_header "Setup Summary"
    echo "============="

    # Directory count
    local total_dirs=$(find . -type d | wc -l)
    local stream_dirs=$(find output -name "stream*" -type d 2>/dev/null | wc -l || echo "0")

    echo "Directories created: $total_dirs total"
    echo "Stream directories: $stream_dirs (ready for $MAX_STREAMS streams)"

    # File count
    local script_count=$(find . -maxdepth 1 -name "*.sh" -o -name "*.py" | wc -l)
    echo "Scripts available: $script_count"

    # Check scripts are executable
    local executable_count=$(find . -maxdepth 1 \( -name "*.sh" -o -name "*.py" \) -executable | wc -l)
    echo "Executable scripts: $executable_count"

    echo ""
    echo "Next steps:"
    echo "1. Run './create-test-videos.sh' to create test inputs"
    echo "2. Run './test-dual-nvenc.sh standard' to start testing"
    echo "3. Use './analyze-results.py' to analyze results"
    echo "4. Check 'USAGE_EXAMPLES.md' for detailed instructions"
}

main() {
    # Step 1: System validation
    local validation_errors=0

    validation_errors+=$(check_system_requirements)
    validation_errors+=$(check_ffmpeg || echo 1)
    validation_errors+=$(check_nvidia_drivers || echo 1)
    check_python_dependencies

    if [[ $validation_errors -gt 0 ]]; then
        print_error "Environment validation failed with $validation_errors errors"
        if [[ "$CHECK_ONLY" == "true" ]]; then
            exit 1
        else
            print_warning "Continuing setup despite validation errors..."
        fi
    else
        print_status "✓ Environment validation passed"
    fi

    # If check-only mode, exit after validation
    if [[ "$CHECK_ONLY" == "true" ]]; then
        print_status "Check-only mode: environment validation completed"
        exit 0
    fi

    # Step 2: Directory setup
    create_directory_structure
    set_permissions

    # Step 3: Documentation
    create_environment_info
    create_usage_examples

    # Step 4: Summary
    show_setup_summary

    print_status "Setup completed successfully!"
}

# Run main function
main