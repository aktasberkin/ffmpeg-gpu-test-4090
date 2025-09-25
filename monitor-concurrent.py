#!/usr/bin/env python3

"""
RTX 4090 Concurrent Stream Monitoring Script
Real-time monitoring for dual-NVENC concurrent stream testing
"""

import subprocess
import time
import json
import csv
import argparse
import signal
import sys
import threading
from datetime import datetime
from pathlib import Path
import psutil
import re

class ConcurrentStreamMonitor:
    def __init__(self, output_dir="./logs", interval=1):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
        self.interval = interval
        self.running = False
        self.data_points = []
        self.ffmpeg_processes = []
        self.nvenc_sessions = []

        # Setup signal handlers
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

    def _signal_handler(self, signum, frame):
        print("\nReceived shutdown signal, saving data...")
        self.running = False

    def get_gpu_info(self):
        """Get comprehensive GPU information optimized for RTX 4090"""
        try:
            # Main GPU metrics
            result = subprocess.run([
                'nvidia-smi',
                '--query-gpu=timestamp,name,memory.total,memory.used,memory.free,utilization.gpu,utilization.memory,temperature.gpu,power.draw,clocks.current.graphics,clocks.current.memory',
                '--format=csv,noheader,nounits'
            ], capture_output=True, text=True, check=True)

            values = result.stdout.strip().split(',')

            gpu_info = {
                'timestamp': values[0].strip(),
                'gpu_name': values[1].strip(),
                'memory_total_mb': int(values[2].strip()),
                'memory_used_mb': int(values[3].strip()),
                'memory_free_mb': int(values[4].strip()),
                'gpu_utilization_%': float(values[5].strip()) if values[5].strip() != '[N/A]' else 0,
                'memory_utilization_%': float(values[6].strip()) if values[6].strip() != '[N/A]' else 0,
                'temperature_c': int(values[7].strip()) if values[7].strip() != '[N/A]' else 0,
                'power_draw_w': float(values[8].strip()) if values[8].strip() != '[N/A]' else 0,
                'gpu_clock_mhz': int(values[9].strip()) if values[9].strip() != '[N/A]' else 0,
                'memory_clock_mhz': int(values[10].strip()) if values[10].strip() != '[N/A]' else 0,
            }

            # Calculate derived metrics
            gpu_info['memory_percent'] = (gpu_info['memory_used_mb'] / gpu_info['memory_total_mb']) * 100

            return gpu_info

        except Exception as e:
            print(f"Error getting GPU info: {e}")
            return None

    def get_nvenc_encoder_stats(self):
        """Try to get NVENC encoder statistics"""
        try:
            # Try to get encoder session count (may not be available on all drivers)
            result = subprocess.run([
                'nvidia-smi',
                '--query-gpu=encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency',
                '--format=csv,noheader,nounits'
            ], capture_output=True, text=True)

            if result.returncode == 0 and result.stdout.strip():
                values = result.stdout.strip().split(',')
                return {
                    'encoder_sessions': int(values[0].strip()) if values[0].strip() != '[N/A]' else 0,
                    'encoder_avg_fps': float(values[1].strip()) if values[1].strip() != '[N/A]' else 0,
                    'encoder_avg_latency_ms': float(values[2].strip()) if values[2].strip() != '[N/A]' else 0,
                }
        except:
            pass

        return {
            'encoder_sessions': 0,
            'encoder_avg_fps': 0,
            'encoder_avg_latency_ms': 0,
        }

    def get_compute_processes(self):
        """Get GPU compute processes"""
        try:
            result = subprocess.run([
                'nvidia-smi',
                '--query-compute-apps=pid,process_name,used_gpu_memory',
                '--format=csv,noheader,nounits'
            ], capture_output=True, text=True, check=True)

            processes = []
            if result.stdout.strip():
                for line in result.stdout.strip().split('\n'):
                    parts = line.split(',')
                    if len(parts) >= 3:
                        processes.append({
                            'pid': int(parts[0].strip()),
                            'process_name': parts[1].strip(),
                            'gpu_memory_mb': int(parts[2].strip())
                        })
            return processes
        except Exception as e:
            return []

    def get_ffmpeg_processes(self):
        """Get detailed FFmpeg process information"""
        ffmpeg_processes = []

        try:
            for proc in psutil.process_iter(['pid', 'name', 'cmdline', 'cpu_percent', 'memory_info', 'create_time']):
                try:
                    if proc.info['name'] == 'ffmpeg' and proc.info['cmdline']:
                        cmdline = ' '.join(proc.info['cmdline'])

                        # Check if it's our NVENC process
                        if 'h264_nvenc' in cmdline:
                            # Count input streams
                            input_count = cmdline.count(' -i ')

                            # Extract process info
                            process_info = {
                                'pid': proc.info['pid'],
                                'input_streams': input_count,
                                'cpu_percent': proc.cpu_percent(),
                                'memory_mb': proc.info['memory_info'].rss / 1024 / 1024 if proc.info['memory_info'] else 0,
                                'runtime_seconds': time.time() - proc.info['create_time'] if proc.info['create_time'] else 0,
                                'cmdline_sample': cmdline[:200] + '...' if len(cmdline) > 200 else cmdline
                            }

                            ffmpeg_processes.append(process_info)

                except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                    continue

        except Exception as e:
            print(f"Error getting FFmpeg processes: {e}")

        return ffmpeg_processes

    def get_system_info(self):
        """Get system resource information"""
        try:
            cpu_percent = psutil.cpu_percent(interval=None)
            memory = psutil.virtual_memory()

            # Get per-core CPU usage for detailed monitoring
            cpu_per_core = psutil.cpu_percent(percpu=True, interval=None)

            return {
                'cpu_percent_total': cpu_percent,
                'cpu_cores_count': psutil.cpu_count(),
                'cpu_cores_usage': cpu_per_core,
                'cpu_max_core': max(cpu_per_core) if cpu_per_core else 0,
                'memory_total_gb': memory.total / 1024**3,
                'memory_used_gb': memory.used / 1024**3,
                'memory_available_gb': memory.available / 1024**3,
                'memory_percent': memory.percent,
                'load_average': psutil.getloadavg() if hasattr(psutil, 'getloadavg') else [0, 0, 0],
            }
        except Exception as e:
            print(f"Error getting system info: {e}")
            return {}

    def get_hls_output_stats(self, output_dir="./output"):
        """Monitor HLS output generation"""
        try:
            output_path = Path(output_dir)
            if not output_path.exists():
                return {'total_playlists': 0, 'total_segments': 0, 'total_size_mb': 0}

            playlist_count = len(list(output_path.rglob("*.m3u8")))
            segment_count = len(list(output_path.rglob("*.ts")))

            # Calculate total output size
            total_size = 0
            for file_path in output_path.rglob("*"):
                if file_path.is_file():
                    total_size += file_path.stat().st_size

            return {
                'total_playlists': playlist_count,
                'total_segments': segment_count,
                'total_size_mb': total_size / 1024 / 1024,
                'avg_segments_per_playlist': segment_count / playlist_count if playlist_count > 0 else 0
            }
        except Exception as e:
            return {'total_playlists': 0, 'total_segments': 0, 'total_size_mb': 0, 'avg_segments_per_playlist': 0}

    def detect_nvenc_utilization(self, ffmpeg_processes):
        """Estimate NVENC utilization based on active processes"""
        if not ffmpeg_processes:
            return {'nvenc1_estimated_load': 0, 'nvenc2_estimated_load': 0, 'total_concurrent_streams': 0}

        # Sort processes by PID to have consistent assignment
        sorted_processes = sorted(ffmpeg_processes, key=lambda x: x['pid'])

        total_streams = sum(p['input_streams'] for p in sorted_processes)

        if len(sorted_processes) == 1:
            # Single process - assume all streams on one NVENC
            return {
                'nvenc1_estimated_load': sorted_processes[0]['input_streams'],
                'nvenc2_estimated_load': 0,
                'total_concurrent_streams': total_streams
            }
        elif len(sorted_processes) >= 2:
            # Dual process - assume first process = NVENC1, second = NVENC2
            return {
                'nvenc1_estimated_load': sorted_processes[0]['input_streams'],
                'nvenc2_estimated_load': sorted_processes[1]['input_streams'],
                'total_concurrent_streams': total_streams
            }

        return {'nvenc1_estimated_load': 0, 'nvenc2_estimated_load': 0, 'total_concurrent_streams': 0}

    def collect_data(self):
        """Collect all monitoring data"""
        timestamp = datetime.now()

        data_point = {
            'timestamp': timestamp.isoformat(),
            'unix_timestamp': timestamp.timestamp()
        }

        # GPU information
        gpu_info = self.get_gpu_info()
        if gpu_info:
            data_point.update(gpu_info)

        # NVENC encoder stats
        nvenc_stats = self.get_nvenc_encoder_stats()
        data_point.update(nvenc_stats)

        # Process information
        compute_processes = self.get_compute_processes()
        ffmpeg_processes = self.get_ffmpeg_processes()

        data_point['compute_processes'] = compute_processes
        data_point['ffmpeg_processes'] = ffmpeg_processes
        data_point['total_ffmpeg_processes'] = len(ffmpeg_processes)
        data_point['total_compute_processes'] = len(compute_processes)

        # NVENC utilization estimation
        nvenc_util = self.detect_nvenc_utilization(ffmpeg_processes)
        data_point.update(nvenc_util)

        # System information
        system_info = self.get_system_info()
        data_point.update(system_info)

        # HLS output statistics
        hls_stats = self.get_hls_output_stats()
        data_point.update(hls_stats)

        return data_point

    def print_realtime_status(self, data):
        """Print real-time status with focus on concurrent streaming"""
        gpu_util = data.get('gpu_utilization_%', 0)
        mem_used = data.get('memory_used_mb', 0)
        mem_total = data.get('memory_total_mb', 1)
        temp = data.get('temperature_c', 0)
        power = data.get('power_draw_w', 0)

        nvenc1_load = data.get('nvenc1_estimated_load', 0)
        nvenc2_load = data.get('nvenc2_estimated_load', 0)
        total_streams = data.get('total_concurrent_streams', 0)

        ffmpeg_count = data.get('total_ffmpeg_processes', 0)
        mem_percent = (mem_used / mem_total) * 100

        # Status line with concurrent stream focus
        print(f"\r[{data['timestamp'][:19]}] "
              f"Streams: {total_streams:3d} (NVENC1:{nvenc1_load:2d} NVENC2:{nvenc2_load:2d}) | "
              f"GPU: {gpu_util:5.1f}% | "
              f"VRAM: {mem_used:5d}MB ({mem_percent:4.1f}%) | "
              f"Temp: {temp:2d}°C | "
              f"Power: {power:5.1f}W | "
              f"Proc: {ffmpeg_count}", end='', flush=True)

    def save_data_csv(self, filename):
        """Save monitoring data to CSV with focus on concurrent metrics"""
        if not self.data_points:
            return

        csv_file = self.output_dir / f"{filename}.csv"

        # Flatten data for CSV
        flattened_data = []
        for point in self.data_points:
            flat_point = {}

            # Core metrics
            for key, value in point.items():
                if not isinstance(value, (list, dict)):
                    flat_point[key] = value

            # Add derived metrics for concurrent testing
            flat_point['total_streams'] = point.get('total_concurrent_streams', 0)
            flat_point['nvenc1_load'] = point.get('nvenc1_estimated_load', 0)
            flat_point['nvenc2_load'] = point.get('nvenc2_estimated_load', 0)
            flat_point['ffmpeg_process_count'] = len(point.get('ffmpeg_processes', []))
            flat_point['compute_process_count'] = len(point.get('compute_processes', []))

            flattened_data.append(flat_point)

        with open(csv_file, 'w', newline='') as f:
            if flattened_data:
                writer = csv.DictWriter(f, fieldnames=flattened_data[0].keys())
                writer.writeheader()
                writer.writerows(flattened_data)

        print(f"\nCSV data saved to {csv_file}")

    def save_data_json(self, filename):
        """Save detailed data to JSON"""
        json_file = self.output_dir / f"{filename}.json"

        with open(json_file, 'w') as f:
            json.dump(self.data_points, f, indent=2, default=str)

        print(f"Detailed JSON data saved to {json_file}")

    def analyze_concurrent_performance(self):
        """Analyze performance specifically for concurrent stream testing"""
        if not self.data_points:
            return {}

        analysis = {}

        # GPU utilization during concurrent streaming
        gpu_utils = [p.get('gpu_utilization_%', 0) for p in self.data_points]
        analysis['gpu_utilization'] = {
            'avg': sum(gpu_utils) / len(gpu_utils),
            'max': max(gpu_utils),
            'min': min(gpu_utils),
            'stable_above_50': sum(1 for x in gpu_utils if x > 50) / len(gpu_utils)
        }

        # Memory usage patterns
        mem_percents = [p.get('memory_percent', 0) for p in self.data_points]
        analysis['memory_usage'] = {
            'avg_percent': sum(mem_percents) / len(mem_percents),
            'max_percent': max(mem_percents),
            'max_mb': max(p.get('memory_used_mb', 0) for p in self.data_points)
        }

        # Concurrent stream statistics
        stream_counts = [p.get('total_concurrent_streams', 0) for p in self.data_points]
        nvenc1_loads = [p.get('nvenc1_estimated_load', 0) for p in self.data_points]
        nvenc2_loads = [p.get('nvenc2_estimated_load', 0) for p in self.data_points]

        analysis['concurrent_streams'] = {
            'max_total_streams': max(stream_counts) if stream_counts else 0,
            'avg_total_streams': sum(stream_counts) / len(stream_counts) if stream_counts else 0,
            'max_nvenc1_load': max(nvenc1_loads) if nvenc1_loads else 0,
            'max_nvenc2_load': max(nvenc2_loads) if nvenc2_loads else 0,
            'dual_nvenc_utilization': sum(1 for i, _ in enumerate(stream_counts)
                                        if nvenc1_loads[i] > 0 and nvenc2_loads[i] > 0) / len(stream_counts)
        }

        # Thermal and power under load
        temps = [p.get('temperature_c', 0) for p in self.data_points]
        powers = [p.get('power_draw_w', 0) for p in self.data_points]

        analysis['thermal_power'] = {
            'max_temp_c': max(temps) if temps else 0,
            'avg_temp_c': sum(temps) / len(temps) if temps else 0,
            'max_power_w': max(powers) if powers else 0,
            'avg_power_w': sum(powers) / len(powers) if powers else 0
        }

        # HLS output generation
        playlist_counts = [p.get('total_playlists', 0) for p in self.data_points]
        segment_counts = [p.get('total_segments', 0) for p in self.data_points]

        analysis['output_generation'] = {
            'max_playlists': max(playlist_counts) if playlist_counts else 0,
            'max_segments': max(segment_counts) if segment_counts else 0,
            'final_output_size_mb': self.data_points[-1].get('total_size_mb', 0) if self.data_points else 0
        }

        return analysis

    def save_analysis(self, filename):
        """Save concurrent stream performance analysis"""
        analysis = self.analyze_concurrent_performance()
        if not analysis:
            return

        analysis_file = self.output_dir / f"{filename}_analysis.json"

        with open(analysis_file, 'w') as f:
            json.dump(analysis, f, indent=2)

        print(f"\nConcurrent Stream Analysis saved to {analysis_file}")

        # Print key findings
        print(f"\n{'='*50}")
        print("CONCURRENT STREAM PERFORMANCE ANALYSIS")
        print(f"{'='*50}")

        if 'concurrent_streams' in analysis:
            cs = analysis['concurrent_streams']
            print(f"Max Concurrent Streams: {cs['max_total_streams']}")
            print(f"  - NVENC1 Max Load: {cs['max_nvenc1_load']}")
            print(f"  - NVENC2 Max Load: {cs['max_nvenc2_load']}")
            print(f"  - Dual NVENC Usage: {cs['dual_nvenc_utilization']:.1%}")

        if 'gpu_utilization' in analysis:
            gpu = analysis['gpu_utilization']
            print(f"GPU Utilization: {gpu['avg']:.1f}% avg, {gpu['max']:.1f}% max")
            print(f"  - Stable Load (>50%): {gpu['stable_above_50']:.1%}")

        if 'memory_usage' in analysis:
            mem = analysis['memory_usage']
            print(f"VRAM Usage: {mem['avg_percent']:.1f}% avg, {mem['max_percent']:.1f}% max ({mem['max_mb']:.0f}MB)")

        if 'thermal_power' in analysis:
            tp = analysis['thermal_power']
            print(f"Thermal: {tp['avg_temp_c']:.1f}°C avg, {tp['max_temp_c']:.0f}°C max")
            print(f"Power: {tp['avg_power_w']:.1f}W avg, {tp['max_power_w']:.1f}W max")

        if 'output_generation' in analysis:
            out = analysis['output_generation']
            print(f"Output: {out['max_playlists']} playlists, {out['max_segments']} segments")
            print(f"  - Total Size: {out['final_output_size_mb']:.1f}MB")

    def monitor(self, duration=None, output_prefix="concurrent_monitor"):
        """Main monitoring loop optimized for concurrent stream testing"""
        print("RTX 4090 Concurrent Stream Monitor")
        print("==================================")
        if duration:
            print(f"Monitoring duration: {duration}s")
        print("Press Ctrl+C to stop")
        print("Focus: Concurrent NVENC stream performance")
        print()

        self.running = True
        start_time = time.time()

        try:
            while self.running:
                data_point = self.collect_data()
                self.data_points.append(data_point)

                # Print real-time status
                self.print_realtime_status(data_point)

                # Check duration limit
                if duration and (time.time() - start_time) >= duration:
                    print(f"\n\nMonitoring duration ({duration}s) completed")
                    break

                time.sleep(self.interval)

        except KeyboardInterrupt:
            print("\n\nMonitoring interrupted by user")
        finally:
            # Save data
            print("\nSaving monitoring data...")
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self.save_data_csv(f"{output_prefix}_{timestamp}")
            self.save_data_json(f"{output_prefix}_{timestamp}")
            self.save_analysis(f"{output_prefix}_{timestamp}")

def main():
    parser = argparse.ArgumentParser(description='RTX 4090 Concurrent Stream Monitor')
    parser.add_argument('-i', '--interval', type=float, default=1.0,
                       help='Monitoring interval in seconds (default: 1.0)')
    parser.add_argument('-d', '--duration', type=int,
                       help='Monitoring duration in seconds (default: unlimited)')
    parser.add_argument('-o', '--output-dir', type=str, default='./logs',
                       help='Output directory for logs (default: ./logs)')
    parser.add_argument('-p', '--prefix', type=str, default='concurrent_monitor',
                       help='Output file prefix (default: concurrent_monitor)')

    args = parser.parse_args()

    monitor = ConcurrentStreamMonitor(output_dir=args.output_dir, interval=args.interval)
    monitor.monitor(duration=args.duration, output_prefix=args.prefix)

if __name__ == "__main__":
    main()