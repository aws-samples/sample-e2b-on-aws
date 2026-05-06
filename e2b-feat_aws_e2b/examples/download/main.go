package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"code.byted.org/capcut-server/e2b"
)

func main() {
	apiKey := os.Getenv("E2B_API_KEY")
	if apiKey == "" {
		log.Fatal("E2B_API_KEY environment variable not set")
	}

	fmt.Println("Creating sandbox...")
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	sandbox, err := e2b.Create(ctx, apiKey, &e2b.SandboxConfig{
		Template: "test-1774540139",
		Timeout:  300,
	})
	if err != nil {
		log.Fatalf("Failed to create sandbox: %v", err)
	}
	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		sandbox.Kill(cleanupCtx)
		fmt.Println("\nSandbox killed.")
	}()
	fmt.Printf("Sandbox created: %s\n", sandbox.ID)

	passed, failed := 0, 0
	test := func(name string, fn func() error) {
		fmt.Printf("\n=== %s ===\n", name)
		if err := fn(); err != nil {
			fmt.Printf("  FAIL: %v\n", err)
			failed++
		} else {
			fmt.Println("  PASS")
			passed++
		}
	}

	// -------------------------------------------------------
	// Test 1: Write text file
	// -------------------------------------------------------
	test("Write text file", func() error {
		content := []byte("Hello, E2B sandbox!")
		_, err := sandbox.Files().Write(ctx, "/tmp/test_write.txt", content, nil)
		if err != nil {
			return fmt.Errorf("Write failed: %v", err)
		}
		fmt.Printf("  wrote %d bytes to /tmp/test_write.txt\n", len(content))
		return nil
	})

	// -------------------------------------------------------
	// Test 2: ReadBytes - read back text file and verify content
	// -------------------------------------------------------
	test("ReadBytes text file", func() error {
		data, err := sandbox.Files().ReadBytes(ctx, "/tmp/test_write.txt", nil)
		if err != nil {
			return fmt.Errorf("ReadBytes failed: %v", err)
		}
		expected := []byte("Hello, E2B sandbox!")
		if !bytes.Equal(data, expected) {
			return fmt.Errorf("content mismatch: got %q, want %q", string(data), string(expected))
		}
		fmt.Printf("  read %d bytes, content matches\n", len(data))
		return nil
	})

	// -------------------------------------------------------
	// Test 3: Write binary data
	// -------------------------------------------------------
	test("Write binary data", func() error {
		binData := make([]byte, 256)
		for i := range binData {
			binData[i] = byte(i)
		}
		_, err := sandbox.Files().Write(ctx, "/tmp/test_binary.bin", binData, nil)
		if err != nil {
			return fmt.Errorf("Write binary failed: %v", err)
		}
		fmt.Printf("  wrote %d bytes binary data\n", len(binData))
		return nil
	})

	// -------------------------------------------------------
	// Test 4: ReadBytes - read back binary data and verify
	// -------------------------------------------------------
	test("ReadBytes binary data", func() error {
		data, err := sandbox.Files().ReadBytes(ctx, "/tmp/test_binary.bin", nil)
		if err != nil {
			return fmt.Errorf("ReadBytes binary failed: %v", err)
		}
		if len(data) != 256 {
			return fmt.Errorf("size mismatch: got %d, want 256", len(data))
		}
		for i, b := range data {
			if b != byte(i) {
				return fmt.Errorf("byte mismatch at index %d: got %d, want %d", i, b, byte(i))
			}
		}
		fmt.Printf("  read %d bytes, all bytes match\n", len(data))
		return nil
	})

	// -------------------------------------------------------
	// Test 5: Write large file (1MB)
	// -------------------------------------------------------
	test("Write large file (1MB)", func() error {
		bigData := bytes.Repeat([]byte("ABCDEFGHIJ"), 100000) // 1MB
		_, err := sandbox.Files().Write(ctx, "/tmp/test_large.dat", bigData, nil)
		if err != nil {
			return fmt.Errorf("Write large file failed: %v", err)
		}
		fmt.Printf("  wrote %d bytes\n", len(bigData))
		return nil
	})

	// -------------------------------------------------------
	// Test 6: ReadBytes large file
	// -------------------------------------------------------
	test("ReadBytes large file (1MB)", func() error {
		data, err := sandbox.Files().ReadBytes(ctx, "/tmp/test_large.dat", nil)
		if err != nil {
			return fmt.Errorf("ReadBytes large file failed: %v", err)
		}
		if len(data) != 1000000 {
			return fmt.Errorf("size mismatch: got %d, want 1000000", len(data))
		}
		fmt.Printf("  read %d bytes\n", len(data))
		return nil
	})

	// -------------------------------------------------------
	// Test 7: Read non-existent file
	// -------------------------------------------------------
	test("ReadBytes non-existent file", func() error {
		_, err := sandbox.Files().ReadBytes(ctx, "/tmp/does_not_exist_12345.txt", nil)
		if err == nil {
			return fmt.Errorf("expected error for non-existent file, got nil")
		}
		fmt.Printf("  got expected error: %v\n", err)
		return nil
	})

	// -------------------------------------------------------
	// Test 8: Write then Read (string)
	// -------------------------------------------------------
	test("Write then Read (string)", func() error {
		text := "中文内容测试 UTF-8 🚀"
		_, err := sandbox.Files().Write(ctx, "/tmp/test_utf8.txt", []byte(text), nil)
		if err != nil {
			return fmt.Errorf("Write failed: %v", err)
		}
		content, err := sandbox.Files().Read(ctx, "/tmp/test_utf8.txt", nil)
		if err != nil {
			return fmt.Errorf("Read failed: %v", err)
		}
		if content != text {
			return fmt.Errorf("content mismatch: got %q, want %q", content, text)
		}
		fmt.Printf("  UTF-8 content matches: %s\n", content)
		return nil
	})

	// -------------------------------------------------------
	// Summary
	// -------------------------------------------------------
	fmt.Printf("\n=============================\n")
	fmt.Printf("RESULTS: %d passed, %d failed\n", passed, failed)
	fmt.Printf("=============================\n")
}
