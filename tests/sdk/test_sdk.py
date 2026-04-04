#!/usr/bin/env python3
"""
E2B Python SDK full test suite for self-hosted AWS deployment.

Usage:
    export E2B_DOMAIN="your-domain.com"
    export E2B_API_KEY="e2b_xxx"
    export E2B_ACCESS_TOKEN="sk_e2b_xxx"
    python3 test_sdk.py

Tests:
    1. Template build (SDK v2)
    2. Sandbox create & basic info
    3. Command execution
    4. File write & read
    5. File upload & download
    6. Process management (background)
    7. Environment variables
    8. Sandbox timeout & metadata
    9. Sandbox list
   10. Sandbox kill & cleanup
"""

import os
import sys
import time
import traceback

# Verify env vars
for var in ["E2B_DOMAIN", "E2B_API_KEY"]:
    if not os.environ.get(var):
        print(f"Error: {var} not set")
        sys.exit(1)

from e2b import (
    Sandbox,
    Template,
    default_build_logger,
    CommandResult,
)

PASSED = 0
FAILED = 0
TEMPLATE_ID = None


def run_test(name, fn):
    global PASSED, FAILED
    print(f"\n{'='*60}")
    print(f"TEST: {name}")
    print(f"{'='*60}")
    try:
        fn()
        PASSED += 1
        print(f"  ✓ PASSED")
    except Exception as e:
        FAILED += 1
        print(f"  ✗ FAILED: {e}")
        traceback.print_exc()


# ============================================================
# Test 1: Template Build
# ============================================================
def test_template_build():
    global TEMPLATE_ID

    template = (
        Template()
        .from_image("e2bdev/base")
        .run_cmd("echo 'SDK test template ready'")
    )

    build = Template.build(
        template,
        "sdk-test-template",
        on_build_logs=default_build_logger(),
    )

    TEMPLATE_ID = build.template_id
    assert TEMPLATE_ID, "Template ID should not be empty"
    print(f"  Template ID: {TEMPLATE_ID}")


# ============================================================
# Test 2: Sandbox Create & Info
# ============================================================
sandbox = None


def test_sandbox_create():
    global sandbox

    sandbox = Sandbox.create(
        template=TEMPLATE_ID,
        timeout=120,
        metadata={"test": "sdk-test", "created_by": "test_sdk.py"},
    )

    assert sandbox.sandbox_id, "Sandbox ID should not be empty"
    assert sandbox.is_running(), "Sandbox should be running"
    print(f"  Sandbox ID: {sandbox.sandbox_id}")

    info = sandbox.get_info()
    print(f"  Template:   {info.template_id}")
    print(f"  Started:    {info.started_at}")


# ============================================================
# Test 3: Command Execution
# ============================================================
def test_commands():
    # Simple command
    result = sandbox.commands.run("echo 'Hello from E2B!'")
    assert result.exit_code == 0, f"Exit code should be 0, got {result.exit_code}"
    assert "Hello from E2B!" in result.stdout, f"Unexpected stdout: {result.stdout}"
    print(f"  echo: {result.stdout.strip()}")

    # Command with stderr
    result = sandbox.commands.run("ls /nonexistent 2>&1 || true")
    print(f"  ls error: {result.stdout.strip()[:50]}")

    # Multi-line command
    result = sandbox.commands.run("for i in 1 2 3; do echo $i; done")
    assert result.exit_code == 0
    lines = result.stdout.strip().split("\n")
    assert len(lines) == 3, f"Expected 3 lines, got {len(lines)}"
    print(f"  loop: {lines}")

    # Command with non-zero exit code (SDK raises CommandExitException)
    from e2b import CommandExitException
    try:
        sandbox.commands.run("exit 42")
        assert False, "Should have raised CommandExitException"
    except CommandExitException as e:
        assert e.exit_code == 42, f"Expected exit code 42, got {e.exit_code}"
        print(f"  exit 42: caught CommandExitException, code={e.exit_code}")


# ============================================================
# Test 4: File Write & Read
# ============================================================
def test_file_write_read():
    test_content = "Hello from E2B SDK test!\nLine 2\nLine 3\n"

    # Write file
    sandbox.files.write("/tmp/test.txt", test_content)
    print(f"  Written /tmp/test.txt ({len(test_content)} bytes)")

    # Read file
    content = sandbox.files.read("/tmp/test.txt")
    assert content == test_content, f"Content mismatch: {content!r} != {test_content!r}"
    print(f"  Read back: {len(content)} bytes, matches")

    # List directory
    entries = sandbox.files.list("/tmp")
    names = [e.name for e in entries]
    assert "test.txt" in names, f"test.txt not found in /tmp: {names}"
    print(f"  /tmp listing: {len(entries)} entries, test.txt found")

    # Write binary-like content
    sandbox.files.write("/tmp/data.bin", "BINARY\x00DATA\x01TEST")
    result = sandbox.commands.run("wc -c < /tmp/data.bin")
    print(f"  Binary file: {result.stdout.strip()} bytes")


# ============================================================
# Test 5: File Upload & Download URL
# ============================================================
def test_file_urls():
    # Write a file first
    sandbox.files.write("/tmp/download-test.txt", "Download me!")

    # Get download URL
    url = sandbox.download_url("/tmp/download-test.txt")
    assert url, "Download URL should not be empty"
    assert "https://" in url, f"URL should be HTTPS: {url[:50]}"
    print(f"  Download URL: {url[:80]}...")

    # Get upload URL
    url = sandbox.upload_url("/tmp/upload-target.txt")
    assert url, "Upload URL should not be empty"
    print(f"  Upload URL: {url[:80]}...")


# ============================================================
# Test 6: Background Process
# ============================================================
def test_background_process():
    # Start background process
    handle = sandbox.commands.run("sleep 30 & echo $!", background=True)
    print(f"  Background process started")

    # Check running processes
    result = sandbox.commands.run("ps aux | grep 'sleep 30' | grep -v grep | wc -l")
    count = int(result.stdout.strip())
    assert count >= 1, f"Expected at least 1 sleep process, got {count}"
    print(f"  Sleep processes running: {count}")

    # Kill it (pkill may return non-zero, catch exception)
    from e2b import CommandExitException
    try:
        sandbox.commands.run("pkill -f 'sleep 30'")
    except CommandExitException:
        pass
    time.sleep(1)
    result = sandbox.commands.run("ps aux | grep 'sleep 30' | grep -v grep | wc -l")
    print(f"  After kill: {result.stdout.strip()} processes")


# ============================================================
# Test 7: Environment Variables
# ============================================================
def test_env_vars():
    # Create sandbox with custom envs
    sbx = Sandbox.create(
        template=TEMPLATE_ID,
        timeout=60,
        envs={"MY_VAR": "hello_e2b", "MY_NUM": "42"},
    )

    try:
        result = sbx.commands.run("echo $MY_VAR")
        assert "hello_e2b" in result.stdout, f"MY_VAR not set: {result.stdout}"
        print(f"  MY_VAR={result.stdout.strip()}")

        result = sbx.commands.run("echo $MY_NUM")
        assert "42" in result.stdout, f"MY_NUM not set: {result.stdout}"
        print(f"  MY_NUM={result.stdout.strip()}")
    finally:
        sbx.kill()
        print(f"  Env sandbox killed")


# ============================================================
# Test 8: Sandbox Timeout & Metadata
# ============================================================
def test_timeout_metadata():
    info = sandbox.get_info()
    assert info.metadata.get("test") == "sdk-test", f"Metadata mismatch: {info.metadata}"
    print(f"  Metadata: {info.metadata}")

    # Extend timeout
    sandbox.set_timeout(180)
    print(f"  Timeout extended to 180s")


# ============================================================
# Test 9: Sandbox List
# ============================================================
def test_sandbox_list():
    all_sandboxes = []
    paginator = Sandbox.list()
    all_sandboxes.extend(paginator.next_items())
    while paginator.has_next:
        paginator = Sandbox.list(next_token=paginator.next_token)
        all_sandboxes.extend(paginator.next_items())
    ids = [s.sandbox_id for s in all_sandboxes]
    assert sandbox.sandbox_id in ids, f"Current sandbox not in list: {ids}"
    print(f"  Active sandboxes: {len(all_sandboxes)}")
    for s in all_sandboxes:
        print(f"    {s.sandbox_id} (template={s.template_id})")


# ============================================================
# Test 10: Sandbox Kill & Cleanup
# ============================================================
def test_sandbox_kill():
    sid = sandbox.sandbox_id
    sandbox.kill()
    print(f"  Killed sandbox {sid}")

    # Verify it's gone
    time.sleep(2)
    all_sandboxes = []
    paginator = Sandbox.list()
    all_sandboxes.extend(paginator.next_items())
    while paginator.has_next:
        paginator = Sandbox.list(next_token=paginator.next_token)
        all_sandboxes.extend(paginator.next_items())
    ids = [s.sandbox_id for s in all_sandboxes]
    assert sid not in ids, f"Sandbox {sid} still in list after kill"
    print(f"  Verified sandbox removed from list")

    # Kill any remaining test sandboxes
    for s in all_sandboxes:
        if s.metadata and s.metadata.get("test") == "sdk-test":
            Sandbox.kill(s.sandbox_id)
            print(f"  Cleaned up leftover sandbox {s.sandbox_id}")


# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    print("=" * 60)
    print("E2B Python SDK Test Suite")
    print(f"Domain: {os.environ.get('E2B_DOMAIN')}")
    print("=" * 60)

    run_test("1. Template Build (SDK v2)", test_template_build)
    run_test("2. Sandbox Create & Info", test_sandbox_create)
    run_test("3. Command Execution", test_commands)
    run_test("4. File Write & Read", test_file_write_read)
    run_test("5. File Upload & Download URLs", test_file_urls)
    run_test("6. Background Process", test_background_process)
    run_test("7. Environment Variables", test_env_vars)
    run_test("8. Timeout & Metadata", test_timeout_metadata)
    run_test("9. Sandbox List", test_sandbox_list)
    run_test("10. Sandbox Kill & Cleanup", test_sandbox_kill)

    print("\n" + "=" * 60)
    print(f"RESULTS: {PASSED} passed, {FAILED} failed, {PASSED + FAILED} total")
    print("=" * 60)

    sys.exit(1 if FAILED > 0 else 0)
