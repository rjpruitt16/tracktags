#!/usr/bin/env python3
"""
TracktTags Integration Test Runner
Manages the lifecycle of services and runs HURL tests
"""

import os
import sys
import time
import subprocess
import signal
import argparse
from pathlib import Path

# ANSI color codes
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

class TestRunner:
    def __init__(self):
        self.processes = []
        self.test_results = []
        
    def cleanup(self):
        """Clean up all started processes"""
        for proc in self.processes:
            try:
                proc.terminate()
                proc.wait(timeout=5)
            except:
                proc.kill()
        self.processes = []

    def start_service(self, name, command, wait_for_output=None, timeout=30):
        """Start a service and optionally wait for specific output"""
        print(f"{BLUE}Starting {name}...{RESET}")
        
        # Start the process
        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            shell=True,
            preexec_fn=os.setsid if sys.platform != 'win32' else None
        )
        
        self.processes.append(proc)
        
        if wait_for_output:
            start_time = time.time()
            while time.time() - start_time < timeout:
                line = proc.stdout.readline()
                if line:
                    print(f"  {name}: {line.strip()}")
                    if wait_for_output in line:
                        print(f"{GREEN}✓ {name} started successfully{RESET}")
                        return True
                
                # Check if process died
                if proc.poll() is not None:
                    print(f"{RED}✗ {name} exited unexpectedly{RESET}")
                    return False
                    
            print(f"{YELLOW}⚠ {name} started but didn't see expected output{RESET}")
        
        return True

    def check_service_health(self, url, timeout=30):
        """Check if a service is healthy"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                result = subprocess.run(
                    ['curl', '-f', '-s', url],
                    capture_output=True,
                    timeout=5
                )
                if result.returncode == 0:
                    return True
            except:
                pass
            time.sleep(1)
        return False

    def run_hurl_test(self, test_file, test_id, tracktags_url, proxy_target_url, admin_secret_key):
        """Run a single HURL test file"""
        print(f"\n{BLUE}{'='*50}{RESET}")
        print(f"{BLUE}Running: {test_file}{RESET}")
        print(f"{BLUE}{'='*50}{RESET}")
        
        cmd = [
            'hurl', '--test', '--retry', '3', '--retry-interval', '2000', '--very-verbose',
            '--variable', f'ADMIN_SECRET_KEY={admin_secret_key}',
            '--variable', f'TRACKTAGS_URL={tracktags_url}',
            '--variable', f'PROXY_TARGET_URL={proxy_target_url}',
            '--variable', f'test_id={test_id}',
            test_file
        ]
        
        print(f"Running command: {' '.join(cmd)}")
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        # Print stderr if there's any output
        if result.stderr:
            print(f"STDERR: {result.stderr}")
        
        # Check result
        if result.returncode == 0:
            print(f"{GREEN}✓ Test passed: {test_file}{RESET}")
            return True
        else:
            print(f"{RED}✗ Test failed: {test_file}{RESET}")
            if result.stdout:
                print(f"\nOutput:\n{result.stdout}")
            return False

    def run_tests(self, pattern=None, skip_services=False, verbose=False):
        """Run all integration tests"""
        # Get test directory
        test_dir = Path(__file__).parent
        
        # Get configuration from environment or defaults
        tracktags_url = os.getenv('TRACKTAGS_URL', 'http://localhost:8080')
        proxy_target_url = os.getenv('PROXY_TARGET_URL', 'http://localhost:9090/webhook')
        admin_secret_key = os.getenv('ADMIN_SECRET_KEY', 'admin_secret_key_123')
        
        # Generate unique test ID
        test_id = str(int(time.time() * 1000))
        
        # Start services if not skipping
        if not skip_services:
            print(f"\n{BLUE}Starting services...{RESET}")
            
            # Start webhook server
            if not self.start_service(
                "Webhook Server",
                f"python3 {test_dir}/webhook_server.py",
                wait_for_output="Webhook server running",
                timeout=10
            ):
                print(f"{RED}Failed to start webhook server{RESET}")
                return False
            
            # Wait a bit for services to stabilize
            time.sleep(2)
            
            # Check TracktTags health
            print(f"{BLUE}Checking TracktTags health...{RESET}")
            if not self.check_service_health(f"{tracktags_url}/health"):
                print(f"{RED}TracktTags is not healthy at {tracktags_url}{RESET}")
                return False
            print(f"{GREEN}✓ TracktTags is healthy{RESET}")
        
        # Find and run test files
        test_files = []
        if pattern:
            # Use pattern to filter tests
            test_files = list(test_dir.glob(pattern))
        else:
            # Run all .hurl files
            test_files = list(test_dir.glob("*.hurl"))
        
        if not test_files:
            print(f"{YELLOW}No test files found{RESET}")
            return True
        
        print(f"\n{BLUE}Running {len(test_files)} test file(s)...{RESET}")
        
        # Run each test
        failed_tests = []
        for test_file in sorted(test_files):
            success = self.run_hurl_test(
                str(test_file),
                test_id,
                tracktags_url,
                proxy_target_url,
                admin_secret_key
            )
            
            if not success:
                failed_tests.append(test_file.name)
        
        # Print summary
        print(f"\n{BLUE}{'='*50}{RESET}")
        if failed_tests:
            print(f"{RED}✗ {len(failed_tests)} test(s) failed:{RESET}")
            for test in failed_tests:
                print(f"  - {test}")
        else:
            print(f"{GREEN}✓ All tests passed!{RESET}")
        
        print(f"\n{YELLOW}Note: Tests {'failed but continuing anyway' if failed_tests else 'completed successfully'}{RESET}")
        
        return len(failed_tests) == 0

def signal_handler(signum, frame):
    """Handle shutdown signals"""
    print(f"\n{YELLOW}Received interrupt signal, cleaning up...{RESET}")
    sys.exit(0)

def main():
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Parse arguments
    parser = argparse.ArgumentParser(description='Run TracktTags integration tests')
    parser.add_argument('--pattern', help='Pattern to match test files')
    parser.add_argument('--skip-services', action='store_true', 
                       help='Skip starting services (assume they are already running)')
    parser.add_argument('--verbose', action='store_true', help='Verbose output')
    
    args = parser.parse_args()
    
    # Create and run test runner
    runner = TestRunner()
    try:
        success = runner.run_tests(
            pattern=args.pattern,
            skip_services=args.skip_services,
            verbose=args.verbose
        )
        sys.exit(0 if success else 1)
    finally:
        runner.cleanup()

if __name__ == '__main__':
    main()
