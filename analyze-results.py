#!/usr/bin/env python3

"""
RTX 4090 Concurrent Stream Test Results Analyzer
Analyzes test results, generates reports, and provides insights
"""

import json
import csv
import argparse
import sys
from pathlib import Path
from datetime import datetime
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

class ResultsAnalyzer:
    def __init__(self, logs_dir="./logs", output_dir="./output"):
        self.logs_dir = Path(logs_dir)
        self.output_dir = Path(output_dir)
        self.analysis_results = {}

    def find_log_files(self):
        """Find all relevant log files from the test"""
        log_files = {
            'gpu_monitoring': None,
            'concurrent_monitoring': None,
            'test_summary': None,
            'nvenc1_log': None,
            'nvenc2_log': None
        }

        # Find GPU monitoring files
        gpu_csv_files = list(self.logs_dir.glob("*monitor*.csv"))
        if gpu_csv_files:
            log_files['gpu_monitoring'] = max(gpu_csv_files, key=lambda x: x.stat().st_mtime)

        concurrent_csv_files = list(self.logs_dir.glob("concurrent_monitor*.csv"))
        if concurrent_csv_files:
            log_files['concurrent_monitoring'] = max(concurrent_csv_files, key=lambda x: x.stat().st_mtime)

        # Find test summary
        summary_files = list(self.logs_dir.glob("test_summary.txt"))
        if summary_files:
            log_files['test_summary'] = summary_files[0]

        # Find FFmpeg process logs
        nvenc1_logs = list(self.logs_dir.glob("nvenc1_process.log"))
        if nvenc1_logs:
            log_files['nvenc1_log'] = nvenc1_logs[0]

        nvenc2_logs = list(self.logs_dir.glob("nvenc2_process.log"))
        if nvenc2_logs:
            log_files['nvenc2_log'] = nvenc2_logs[0]

        return log_files

    def analyze_gpu_performance(self, csv_file):
        """Analyze GPU performance metrics"""
        if not csv_file or not csv_file.exists():
            return {}

        try:
            df = pd.read_csv(csv_file)

            analysis = {
                'gpu_utilization': {
                    'avg': df['gpu_utilization_%'].mean() if 'gpu_utilization_%' in df else 0,
                    'max': df['gpu_utilization_%'].max() if 'gpu_utilization_%' in df else 0,
                    'min': df['gpu_utilization_%'].min() if 'gpu_utilization_%' in df else 0,
                    'std': df['gpu_utilization_%'].std() if 'gpu_utilization_%' in df else 0
                },
                'memory_usage': {
                    'avg_mb': df['memory_used_mb'].mean() if 'memory_used_mb' in df else 0,
                    'max_mb': df['memory_used_mb'].max() if 'memory_used_mb' in df else 0,
                    'avg_percent': df['memory_percent'].mean() if 'memory_percent' in df else 0,
                    'max_percent': df['memory_percent'].max() if 'memory_percent' in df else 0
                },
                'thermal': {
                    'avg_temp': df['temperature_c'].mean() if 'temperature_c' in df else 0,
                    'max_temp': df['temperature_c'].max() if 'temperature_c' in df else 0,
                    'avg_power': df['power_draw_w'].mean() if 'power_draw_w' in df else 0,
                    'max_power': df['power_draw_w'].max() if 'power_draw_w' in df else 0
                }
            }

            # Add concurrent stream specific metrics
            if 'total_concurrent_streams' in df:
                analysis['concurrent_streams'] = {
                    'max_total': df['total_concurrent_streams'].max(),
                    'avg_total': df['total_concurrent_streams'].mean(),
                    'max_nvenc1': df['nvenc1_estimated_load'].max() if 'nvenc1_estimated_load' in df else 0,
                    'max_nvenc2': df['nvenc2_estimated_load'].max() if 'nvenc2_estimated_load' in df else 0
                }

            return analysis

        except Exception as e:
            print(f"Error analyzing GPU performance: {e}")
            return {}

    def analyze_output_quality(self):
        """Analyze the quality and completeness of generated output"""
        analysis = {
            'nvenc1': {'successful_streams': 0, 'failed_streams': 0, 'total_size_mb': 0},
            'nvenc2': {'successful_streams': 0, 'failed_streams': 0, 'total_size_mb': 0}
        }

        # Analyze NVENC1 outputs
        nvenc1_dir = self.output_dir / 'nvenc1'
        if nvenc1_dir.exists():
            for stream_dir in nvenc1_dir.iterdir():
                if stream_dir.is_dir() and stream_dir.name.startswith('stream'):
                    playlist_file = stream_dir / 'playlist.m3u8'
                    if playlist_file.exists() and playlist_file.stat().st_size > 0:
                        analysis['nvenc1']['successful_streams'] += 1
                        # Calculate directory size
                        dir_size = sum(f.stat().st_size for f in stream_dir.rglob('*') if f.is_file())
                        analysis['nvenc1']['total_size_mb'] += dir_size / (1024 * 1024)
                    else:
                        analysis['nvenc1']['failed_streams'] += 1

        # Analyze NVENC2 outputs
        nvenc2_dir = self.output_dir / 'nvenc2'
        if nvenc2_dir.exists():
            for stream_dir in nvenc2_dir.iterdir():
                if stream_dir.is_dir() and stream_dir.name.startswith('stream'):
                    playlist_file = stream_dir / 'playlist.m3u8'
                    if playlist_file.exists() and playlist_file.stat().st_size > 0:
                        analysis['nvenc2']['successful_streams'] += 1
                        # Calculate directory size
                        dir_size = sum(f.stat().st_size for f in stream_dir.rglob('*') if f.is_file())
                        analysis['nvenc2']['total_size_mb'] += dir_size / (1024 * 1024)
                    else:
                        analysis['nvenc2']['failed_streams'] += 1

        # Calculate success rates
        total_nvenc1 = analysis['nvenc1']['successful_streams'] + analysis['nvenc1']['failed_streams']
        total_nvenc2 = analysis['nvenc2']['successful_streams'] + analysis['nvenc2']['failed_streams']

        if total_nvenc1 > 0:
            analysis['nvenc1']['success_rate'] = (analysis['nvenc1']['successful_streams'] / total_nvenc1) * 100
        else:
            analysis['nvenc1']['success_rate'] = 0

        if total_nvenc2 > 0:
            analysis['nvenc2']['success_rate'] = (analysis['nvenc2']['successful_streams'] / total_nvenc2) * 100
        else:
            analysis['nvenc2']['success_rate'] = 0

        return analysis

    def analyze_ffmpeg_logs(self, nvenc1_log, nvenc2_log):
        """Analyze FFmpeg process logs for errors and performance"""
        analysis = {'nvenc1': {}, 'nvenc2': {}}

        # Analyze NVENC1 log
        if nvenc1_log and nvenc1_log.exists():
            try:
                with open(nvenc1_log, 'r') as f:
                    content = f.read()

                analysis['nvenc1'] = {
                    'log_size_kb': nvenc1_log.stat().st_size / 1024,
                    'has_errors': 'error' in content.lower() or 'failed' in content.lower(),
                    'encoding_speed': self._extract_encoding_speed(content),
                    'dropped_frames': self._count_dropped_frames(content),
                    'warnings': content.lower().count('warning')
                }
            except Exception as e:
                analysis['nvenc1'] = {'error': f"Failed to read log: {e}"}

        # Analyze NVENC2 log
        if nvenc2_log and nvenc2_log.exists():
            try:
                with open(nvenc2_log, 'r') as f:
                    content = f.read()

                analysis['nvenc2'] = {
                    'log_size_kb': nvenc2_log.stat().st_size / 1024,
                    'has_errors': 'error' in content.lower() or 'failed' in content.lower(),
                    'encoding_speed': self._extract_encoding_speed(content),
                    'dropped_frames': self._count_dropped_frames(content),
                    'warnings': content.lower().count('warning')
                }
            except Exception as e:
                analysis['nvenc2'] = {'error': f"Failed to read log: {e}"}

        return analysis

    def _extract_encoding_speed(self, log_content):
        """Extract encoding speed from FFmpeg log"""
        import re

        # Look for speed information in FFmpeg output
        speed_pattern = r'speed=\s*([0-9.]+)x'
        matches = re.findall(speed_pattern, log_content)

        if matches:
            speeds = [float(x) for x in matches]
            return {
                'avg_speed': np.mean(speeds),
                'max_speed': np.max(speeds),
                'min_speed': np.min(speeds)
            }
        return {'avg_speed': 0, 'max_speed': 0, 'min_speed': 0}

    def _count_dropped_frames(self, log_content):
        """Count dropped frames from FFmpeg log"""
        import re

        # Look for dropped frame information
        drop_pattern = r'drop=\s*([0-9]+)'
        matches = re.findall(drop_pattern, log_content)

        if matches:
            return max(int(x) for x in matches)
        return 0

    def generate_performance_plots(self, gpu_data_file):
        """Generate performance visualization plots"""
        if not gpu_data_file or not gpu_data_file.exists():
            print("No GPU monitoring data available for plotting")
            return

        try:
            df = pd.read_csv(gpu_data_file)

            # Create a figure with subplots
            fig, axes = plt.subplots(2, 2, figsize=(15, 10))
            fig.suptitle('RTX 4090 Concurrent Stream Performance', fontsize=16)

            # Plot 1: GPU Utilization vs Concurrent Streams
            if 'gpu_utilization_%' in df and 'total_concurrent_streams' in df:
                axes[0, 0].scatter(df['total_concurrent_streams'], df['gpu_utilization_%'], alpha=0.6, s=20)
                axes[0, 0].set_xlabel('Concurrent Streams')
                axes[0, 0].set_ylabel('GPU Utilization (%)')
                axes[0, 0].set_title('GPU Utilization vs Concurrent Streams')
                axes[0, 0].grid(True, alpha=0.3)

            # Plot 2: VRAM Usage over Time
            if 'memory_used_mb' in df:
                time_points = range(len(df))
                axes[0, 1].plot(time_points, df['memory_used_mb'], color='red', linewidth=1.5)
                axes[0, 1].set_xlabel('Time (seconds)')
                axes[0, 1].set_ylabel('VRAM Usage (MB)')
                axes[0, 1].set_title('VRAM Usage Over Time')
                axes[0, 1].grid(True, alpha=0.3)

            # Plot 3: Temperature and Power
            if 'temperature_c' in df and 'power_draw_w' in df:
                ax3a = axes[1, 0]
                ax3b = ax3a.twinx()

                time_points = range(len(df))
                line1 = ax3a.plot(time_points, df['temperature_c'], color='orange', label='Temperature')
                line2 = ax3b.plot(time_points, df['power_draw_w'], color='green', label='Power')

                ax3a.set_xlabel('Time (seconds)')
                ax3a.set_ylabel('Temperature (°C)', color='orange')
                ax3b.set_ylabel('Power (W)', color='green')
                ax3a.set_title('Temperature & Power Over Time')

                # Combine legends
                lines = line1 + line2
                labels = [l.get_label() for l in lines]
                ax3a.legend(lines, labels, loc='upper left')

            # Plot 4: NVENC Load Distribution
            if 'nvenc1_estimated_load' in df and 'nvenc2_estimated_load' in df:
                time_points = range(len(df))
                axes[1, 1].plot(time_points, df['nvenc1_estimated_load'], label='NVENC1', linewidth=1.5)
                axes[1, 1].plot(time_points, df['nvenc2_estimated_load'], label='NVENC2', linewidth=1.5)
                axes[1, 1].set_xlabel('Time (seconds)')
                axes[1, 1].set_ylabel('Streams per NVENC')
                axes[1, 1].set_title('NVENC Load Distribution')
                axes[1, 1].legend()
                axes[1, 1].grid(True, alpha=0.3)

            plt.tight_layout()

            # Save plot
            plot_file = self.logs_dir / 'performance_analysis.png'
            plt.savefig(plot_file, dpi=300, bbox_inches='tight')
            plt.close()

            print(f"Performance plots saved to: {plot_file}")
            return plot_file

        except Exception as e:
            print(f"Error generating plots: {e}")
            return None

    def generate_comprehensive_report(self):
        """Generate a comprehensive analysis report"""
        print("RTX 4090 Concurrent Stream Test - Results Analysis")
        print("=" * 60)

        # Find log files
        log_files = self.find_log_files()

        # Analyze GPU performance
        gpu_analysis = self.analyze_gpu_performance(log_files['concurrent_monitoring'])

        # Analyze output quality
        output_analysis = self.analyze_output_quality()

        # Analyze FFmpeg logs
        ffmpeg_analysis = self.analyze_ffmpeg_logs(log_files['nvenc1_log'], log_files['nvenc2_log'])

        # Generate plots
        plot_file = self.generate_performance_plots(log_files['concurrent_monitoring'])

        # Compile comprehensive analysis
        self.analysis_results = {
            'test_timestamp': datetime.now().isoformat(),
            'log_files': {k: str(v) if v else None for k, v in log_files.items()},
            'gpu_performance': gpu_analysis,
            'output_quality': output_analysis,
            'ffmpeg_analysis': ffmpeg_analysis,
            'plots_generated': str(plot_file) if plot_file else None
        }

        # Print summary
        self._print_analysis_summary()

        # Save detailed analysis
        analysis_file = self.logs_dir / f'analysis_report_{datetime.now().strftime("%Y%m%d_%H%M%S")}.json'
        with open(analysis_file, 'w') as f:
            json.dump(self.analysis_results, f, indent=2, default=str)

        print(f"\nDetailed analysis saved to: {analysis_file}")
        return analysis_file

    def _print_analysis_summary(self):
        """Print a human-readable summary of the analysis"""
        print("\nTEST RESULTS SUMMARY")
        print("=" * 40)

        # GPU Performance Summary
        if 'gpu_performance' in self.analysis_results:
            gpu = self.analysis_results['gpu_performance']

            if 'concurrent_streams' in gpu:
                cs = gpu['concurrent_streams']
                print(f"📊 CONCURRENT STREAMS:")
                print(f"   Max Total Streams: {cs.get('max_total', 0):.0f}")
                print(f"   Max NVENC1 Load:  {cs.get('max_nvenc1', 0):.0f}")
                print(f"   Max NVENC2 Load:  {cs.get('max_nvenc2', 0):.0f}")

            if 'gpu_utilization' in gpu:
                gu = gpu['gpu_utilization']
                print(f"🎯 GPU UTILIZATION:")
                print(f"   Average: {gu.get('avg', 0):.1f}%")
                print(f"   Maximum: {gu.get('max', 0):.1f}%")
                print(f"   Stability (σ): {gu.get('std', 0):.1f}%")

            if 'memory_usage' in gpu:
                mem = gpu['memory_usage']
                print(f"💾 VRAM USAGE:")
                print(f"   Average: {mem.get('avg_mb', 0):.0f}MB ({mem.get('avg_percent', 0):.1f}%)")
                print(f"   Maximum: {mem.get('max_mb', 0):.0f}MB ({mem.get('max_percent', 0):.1f}%)")

            if 'thermal' in gpu:
                thermal = gpu['thermal']
                print(f"🌡️  THERMAL & POWER:")
                print(f"   Avg Temp: {thermal.get('avg_temp', 0):.1f}°C (Max: {thermal.get('max_temp', 0):.0f}°C)")
                print(f"   Avg Power: {thermal.get('avg_power', 0):.1f}W (Max: {thermal.get('max_power', 0):.1f}W)")

        # Output Quality Summary
        if 'output_quality' in self.analysis_results:
            output = self.analysis_results['output_quality']

            print(f"📹 OUTPUT QUALITY:")
            nvenc1_success = output['nvenc1'].get('success_rate', 0)
            nvenc2_success = output['nvenc2'].get('success_rate', 0)

            print(f"   NVENC1 Success: {output['nvenc1'].get('successful_streams', 0)} streams ({nvenc1_success:.1f}%)")
            print(f"   NVENC2 Success: {output['nvenc2'].get('successful_streams', 0)} streams ({nvenc2_success:.1f}%)")

            total_size = output['nvenc1'].get('total_size_mb', 0) + output['nvenc2'].get('total_size_mb', 0)
            print(f"   Total Output: {total_size:.1f}MB")

        # FFmpeg Performance
        if 'ffmpeg_analysis' in self.analysis_results:
            ffmpeg = self.analysis_results['ffmpeg_analysis']

            print(f"⚡ ENCODING PERFORMANCE:")

            if 'nvenc1' in ffmpeg and 'encoding_speed' in ffmpeg['nvenc1']:
                speed1 = ffmpeg['nvenc1']['encoding_speed']
                print(f"   NVENC1 Speed: {speed1.get('avg_speed', 0):.1f}x realtime")

            if 'nvenc2' in ffmpeg and 'encoding_speed' in ffmpeg['nvenc2']:
                speed2 = ffmpeg['nvenc2']['encoding_speed']
                print(f"   NVENC2 Speed: {speed2.get('avg_speed', 0):.1f}x realtime")

        # Overall Assessment
        print(f"\n🏆 OVERALL ASSESSMENT:")
        self._print_performance_grade()

    def _print_performance_grade(self):
        """Print an overall performance grade"""
        score = 0
        max_score = 0

        # GPU utilization score (0-25 points)
        if 'gpu_performance' in self.analysis_results:
            gpu_util = self.analysis_results['gpu_performance'].get('gpu_utilization', {}).get('avg', 0)
            if gpu_util >= 80:
                score += 25
            elif gpu_util >= 60:
                score += 20
            elif gpu_util >= 40:
                score += 15
            elif gpu_util >= 20:
                score += 10
            max_score += 25

        # Success rate score (0-35 points)
        if 'output_quality' in self.analysis_results:
            nvenc1_success = self.analysis_results['output_quality']['nvenc1'].get('success_rate', 0)
            nvenc2_success = self.analysis_results['output_quality']['nvenc2'].get('success_rate', 0)
            avg_success = (nvenc1_success + nvenc2_success) / 2

            if avg_success >= 95:
                score += 35
            elif avg_success >= 90:
                score += 30
            elif avg_success >= 80:
                score += 25
            elif avg_success >= 70:
                score += 20
            max_score += 35

        # Concurrent streams score (0-25 points)
        if 'gpu_performance' in self.analysis_results:
            max_streams = self.analysis_results['gpu_performance'].get('concurrent_streams', {}).get('max_total', 0)
            if max_streams >= 100:
                score += 25
            elif max_streams >= 75:
                score += 20
            elif max_streams >= 50:
                score += 15
            elif max_streams >= 25:
                score += 10
            max_score += 25

        # Thermal stability score (0-15 points)
        if 'gpu_performance' in self.analysis_results:
            max_temp = self.analysis_results['gpu_performance'].get('thermal', {}).get('max_temp', 100)
            if max_temp <= 75:
                score += 15
            elif max_temp <= 80:
                score += 12
            elif max_temp <= 85:
                score += 8
            max_score += 15

        if max_score > 0:
            percentage = (score / max_score) * 100

            if percentage >= 90:
                grade = "A+ (Excellent)"
            elif percentage >= 80:
                grade = "A (Very Good)"
            elif percentage >= 70:
                grade = "B+ (Good)"
            elif percentage >= 60:
                grade = "B (Fair)"
            elif percentage >= 50:
                grade = "C (Needs Improvement)"
            else:
                grade = "D (Poor)"

            print(f"   Performance Grade: {grade}")
            print(f"   Score: {score}/{max_score} ({percentage:.1f}%)")

def main():
    parser = argparse.ArgumentParser(description='RTX 4090 Concurrent Stream Test Results Analyzer')
    parser.add_argument('-l', '--logs-dir', type=str, default='./logs',
                       help='Logs directory (default: ./logs)')
    parser.add_argument('-o', '--output-dir', type=str, default='./output',
                       help='Output directory (default: ./output)')
    parser.add_argument('--no-plots', action='store_true',
                       help='Skip generating performance plots')

    args = parser.parse_args()

    # Check if matplotlib is available for plotting
    global plt, np, pd
    try:
        import matplotlib.pyplot as plt
        import numpy as np
        import pandas as pd
    except ImportError as e:
        if not args.no_plots:
            print(f"Warning: {e}")
            print("Install matplotlib, numpy, and pandas for plotting: pip install matplotlib numpy pandas")
            print("Continuing without plots...")
            args.no_plots = True

    analyzer = ResultsAnalyzer(logs_dir=args.logs_dir, output_dir=args.output_dir)

    try:
        analyzer.generate_comprehensive_report()
    except Exception as e:
        print(f"Error during analysis: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()