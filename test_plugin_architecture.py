#!/usr/bin/env python3
"""
Test Plugin Architecture for Crushcode
Demonstrates JSON-RPC 2.0 communication between Zig core and Python plugin
"""

import subprocess
import json
import sys
import time
from pathlib import Path


def test_plugin_discovery():
    """Test plugin discovery and loading"""
    print("🔍 Testing Plugin Discovery...")

    # Test if plugin file exists
    plugin_path = Path("examples/python_plugin.py")
    if not plugin_path.exists():
        print(f"❌ Plugin not found: {plugin_path}")
        return False

    print(f"✅ Plugin found: {plugin_path}")
    return True


def test_plugin_process():
    """Test plugin process startup and communication"""
    print("\n🚀 Testing Plugin Process...")

    try:
        # Start plugin process
        plugin_process = subprocess.Popen(
            [sys.executable, "examples/python_plugin.py"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=0,
        )

        # Send init request
        init_request = {
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": {
                "name": "test_python_plugin",
                "version": "1.0.0",
                "capabilities": ["text_generation", "code_analysis"],
            },
            "id": 1,
        }

        print(f"→ Sending: {init_request}")

        # Send request
        request_json = json.dumps(init_request) + "\n"
        plugin_process.stdin.write(request_json)
        plugin_process.stdin.flush()

        # Read response
        response_line = plugin_process.stdout.readline()
        if response_line:
            response = json.loads(response_line.strip())
            print(f"← Received: {response}")

            if "result" in response:
                print("✅ Plugin initialized successfully")
                return True, plugin_process
            else:
                print(f"❌ Plugin initialization failed: {response}")
                return False, plugin_process
        else:
            print("❌ No response from plugin")
            return False, plugin_process

    except Exception as e:
        print(f"❌ Plugin process error: {e}")
        return False, None


def test_plugin_execute(plugin_process):
    """Test plugin execution with a simple task"""
    print("\n⚡ Testing Plugin Execution...")

    try:
        # Send execute request
        execute_request = {
            "jsonrpc": "2.0",
            "method": "execute",
            "params": {
                "task": "generate_text",
                "data": {
                    "prompt": "Write a hello world function in Python",
                    "max_tokens": 100,
                },
            },
            "id": 2,
        }

        print(f"→ Sending: {execute_request}")

        # Send request
        request_json = json.dumps(execute_request) + "\n"
        plugin_process.stdin.write(request_json)
        plugin_process.stdin.flush()

        # Read response
        response_line = plugin_process.stdout.readline()
        if response_line:
            response = json.loads(response_line.strip())
            print(f"← Received: {response}")

            if "result" in response:
                print("✅ Plugin executed successfully")
                print(f"📝 Result: {response['result']}")
                return True
            else:
                print(f"❌ Plugin execution failed: {response}")
                return False
        else:
            print("❌ No response from plugin")
            return False

    except Exception as e:
        print(f"❌ Plugin execution error: {e}")
        return False


def test_plugin_health_check(plugin_process):
    """Test plugin health check"""
    print("\n🏥 Testing Plugin Health Check...")

    try:
        # Send health check request
        health_request = {
            "jsonrpc": "2.0",
            "method": "health_check",
            "params": {},
            "id": 3,
        }

        print(f"→ Sending: {health_request}")

        # Send request
        request_json = json.dumps(health_request) + "\n"
        plugin_process.stdin.write(request_json)
        plugin_process.stdin.flush()

        # Read response
        response_line = plugin_process.stdout.readline()
        if response_line:
            response = json.loads(response_line.strip())
            print(f"← Received: {response}")

            if "result" in response and response["result"].get("healthy"):
                print("✅ Plugin health check passed")
                return True
            else:
                print(f"❌ Plugin health check failed: {response}")
                return False
        else:
            print("❌ No response from plugin")
            return False

    except Exception as e:
        print(f"❌ Plugin health check error: {e}")
        return False


def test_plugin_cleanup(plugin_process):
    """Test plugin cleanup"""
    print("\n🧹 Testing Plugin Cleanup...")

    try:
        # Send shutdown request
        shutdown_request = {
            "jsonrpc": "2.0",
            "method": "shutdown",
            "params": {},
            "id": 4,
        }

        print(f"→ Sending: {shutdown_request}")

        # Send request
        request_json = json.dumps(shutdown_request) + "\n"
        plugin_process.stdin.write(request_json)
        plugin_process.stdin.flush()

        # Wait for process to terminate
        try:
            return_code = plugin_process.wait(timeout=5)
            if return_code == 0:
                print("✅ Plugin shutdown cleanly")
                return True
            else:
                print(f"❌ Plugin exited with code: {return_code}")
                return False
        except subprocess.TimeoutExpired:
            print("❌ Plugin shutdown timeout")
            plugin_process.terminate()
            return False

    except Exception as e:
        print(f"❌ Plugin cleanup error: {e}")
        return False


def test_configuration_loading():
    """Test configuration loading"""
    print("\n⚙️ Testing Configuration Loading...")

    config_file = Path("crushcode/PROVIDER_CONFIG_SCHEMA.md")
    if config_file.exists():
        print(f"✅ Configuration schema found: {config_file}")
    else:
        print(f"❌ Configuration schema not found: {config_file}")
        return False

    provider_config = Path("src/config/provider_config.zig")
    if provider_config.exists():
        print(f"✅ Provider config module found: {provider_config}")
    else:
        print(f"❌ Provider config module not found: {provider_config}")
        return False

    return True


def test_build_system():
    """Test if the project builds correctly"""
    print("\n🔨 Testing Build System...")

    try:
        result = subprocess.run(
            ["zig", "build"],
            cwd=Path("crushcode"),
            capture_output=True,
            text=True,
            timeout=60,
        )

        if result.returncode == 0:
            print("✅ Project builds successfully")
            return True
        else:
            print(f"❌ Build failed:")
            print(result.stderr)
            return False

    except subprocess.TimeoutExpired:
        print("❌ Build timeout")
        return False
    except Exception as e:
        print(f"❌ Build error: {e}")
        return False


def main():
    """Run all plugin architecture tests"""
    print("🧪 Testing Crushcode Plugin Architecture")
    print("=" * 50)

    tests_passed = 0
    total_tests = 0

    # Test 1: Configuration loading
    total_tests += 1
    if test_configuration_loading():
        tests_passed += 1

    # Test 2: Build system
    total_tests += 1
    if test_build_system():
        tests_passed += 1

    # Test 3: Plugin discovery
    total_tests += 1
    if test_plugin_discovery():
        tests_passed += 1

    # Test 4: Plugin process and communication
    total_tests += 1
    success, plugin_process = test_plugin_process()
    if success:
        tests_passed += 1

        # Test 5: Plugin execution
        total_tests += 1
        if test_plugin_execute(plugin_process):
            tests_passed += 1

        # Test 6: Plugin health check
        total_tests += 1
        if test_plugin_health_check(plugin_process):
            tests_passed += 1

        # Test 7: Plugin cleanup
        total_tests += 1
        if test_plugin_cleanup(plugin_process):
            tests_passed += 1

    # Summary
    print("\n" + "=" * 50)
    print(f"📊 Test Results: {tests_passed}/{total_tests} passed")

    if tests_passed == total_tests:
        print("🎉 All tests passed! Plugin Architecture is working correctly!")
        return 0
    else:
        print("❌ Some tests failed. Please check the output above.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
