# Claude Code Configuration

## Project Overview
RTX 4090 Dual-NVENC Concurrent Stream Test Suite

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
# Run full test suite
./setup.sh
./create-test-videos.sh
./test-dual-nvenc.sh standard
./analyze-results.py

# Clean up after testing
./cleanup.sh
```

## Notes
- This is a video encoding test suite for RTX 4090 GPU
- Uses dual NVENC encoders for concurrent stream processing
- Automatically commits and pushes changes as requested