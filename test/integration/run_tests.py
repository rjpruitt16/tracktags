#!/usr/bin/env python3
import subprocess
import time
import sys
import os
import glob
import socket

def check_port(port, host='localhost'):
   """Check if a port is open"""
   sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
   sock.settimeout(1)
   result = sock.connect_ex((host, port))
   sock.close()
   return result == 0

def wait_for_service(port, service_name, timeout=20):
   """Wait for a service to be available"""
   print(f"Waiting for {service_name} on port {port}...")
   for i in range(timeout):
       if check_port(port):
           print(f"✓ {service_name} is ready")
           return True
       print(f"  Attempt {i+1}/{timeout}...")
       time.sleep(1)
   print(f"✗ {service_name} failed to start after {timeout}s")
   return False

def main():
   webhook_url = os.getenv('WEBHOOK_URL', 'http://localhost:9090')
   ezthrottle_url = os.getenv('EZTHROTTLE_URL', 'http://localhost:8080')
   webhook_callback_url = os.getenv('WEBHOOK_CALLBACK_URL', 'http://localhost:9090/webhook')
   
   webhook_proc = None
   gleam_proc = None
   
   try:
       # Only start services if not in Docker
       if not os.getenv('DOCKER_ENV'):
           # Kill any existing processes first
           os.system("pkill -f webhook_server.py 2>/dev/null")
           os.system("pkill -f 'gleam run' 2>/dev/null")
           time.sleep(1)
           
           print("Starting webhook server...")
           webhook_proc = subprocess.Popen(
               ["python3", "test/integration/webhook_server.py"],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True
           )
           
           if not wait_for_service(9090, "Webhook server"):
               # Print webhook server output for debugging
               stdout, stderr = webhook_proc.communicate(timeout=1)
               print(f"Webhook stdout: {stdout}")
               print(f"Webhook stderr: {stderr}")
               return 1
           
           print("Starting EZThrottle system...")
           gleam_proc = subprocess.Popen(
               ["gleam", "run"],
               stdout=subprocess.PIPE,
               stderr=subprocess.PIPE,
               text=True
           )
           
           if not wait_for_service(8080, "EZThrottle"):
               # Print gleam output for debugging
               stdout, stderr = gleam_proc.communicate(timeout=1)
               print(f"Gleam stdout: {stdout}")
               print(f"Gleam stderr: {stderr}")
               return 1
       
       # Find all .hurl files
       test_files = sorted(glob.glob("test/integration/*.hurl"))
       
       if not test_files:
           print("No .hurl test files found")
           return 1
       
       print(f"\nRunning {len(test_files)} Hurl test file(s)...")
       
       for test_file in test_files:
           print(f"\n{'='*50}")
           print(f"Running: {os.path.basename(test_file)}")
           print('='*50)
           
           result = subprocess.run([
               "hurl", "--test",
               "--variable", f"WEBHOOK_URL={webhook_url}",
               "--variable", f"EZTHROTTLE_URL={ezthrottle_url}",
               "--variable", f"WEBHOOK_CALLBACK_URL={webhook_callback_url}",
               test_file
           ], capture_output=True, text=True, timeout=30)
           
           if result.stdout:
               print(result.stdout)
           if result.stderr:
               print("STDERR:", result.stderr)
           
           if result.returncode != 0:
               print(f"\n✗ Test failed: {test_file}")
               return 1
           else:
               print(f"✓ Test passed: {os.path.basename(test_file)}")
       
       print("\n" + "="*50)
       print("✓ All tests passed!")
       print("="*50)
       return 0
       
   except subprocess.TimeoutExpired:
       print("\n✗ Tests timed out after 30 seconds")
       return 1
   except Exception as e:
       print(f"\n✗ Unexpected error: {e}")
       import traceback
       traceback.print_exc()
       return 1
   finally:
       print("\nCleaning up processes...")
       if webhook_proc:
           webhook_proc.terminate()
           try:
               webhook_proc.wait(timeout=2)
           except:
               webhook_proc.kill()
       if gleam_proc:
           gleam_proc.terminate()
           try:
               gleam_proc.wait(timeout=2)
           except:
               gleam_proc.kill()
       
       # Clean up any stragglers
       os.system("pkill -f webhook_server.py 2>/dev/null")
       os.system("pkill -f 'gleam run' 2>/dev/null")

if __name__ == "__main__":
   sys.exit(main())
