package env

import (
	"os"
	"testing"
	"time"
)

func TestGetEnv(t *testing.T) {
	// Test cases for different types
	t.Run("String", func(t *testing.T) {
		// Set environment variable
		os.Setenv("TEST_STRING", "hello")
		defer os.Unsetenv("TEST_STRING")

		// Test with existing variable
		result := GetEnv("TEST_STRING", "default")
		if result != "hello" {
			t.Errorf("Expected 'hello', got '%s'", result)
		}

		// Test with non-existent variable
		result = GetEnv("NON_EXISTENT_STRING", "default")
		if result != "default" {
			t.Errorf("Expected 'default', got '%s'", result)
		}

		// Test with empty variable
		os.Setenv("EMPTY_STRING", "")
		defer os.Unsetenv("EMPTY_STRING")
		result = GetEnv("EMPTY_STRING", "default")
		if result != "default" {
			t.Errorf("Expected 'default', got '%s'", result)
		}
	})

	t.Run("Boolean", func(t *testing.T) {
		// Test true value
		os.Setenv("TEST_BOOL_TRUE", "true")
		defer os.Unsetenv("TEST_BOOL_TRUE")
		result := GetEnv("TEST_BOOL_TRUE", false)
		if result != true {
			t.Errorf("Expected true, got %v", result)
		}

		// Test false value
		os.Setenv("TEST_BOOL_FALSE", "false")
		defer os.Unsetenv("TEST_BOOL_FALSE")
		result = GetEnv("TEST_BOOL_FALSE", true)
		if result != false {
			t.Errorf("Expected false, got %v", result)
		}

		// Test with invalid boolean
		os.Setenv("TEST_BOOL_INVALID", "not-a-bool")
		defer os.Unsetenv("TEST_BOOL_INVALID")
		result = GetEnv("TEST_BOOL_INVALID", true)
		if result != true {
			t.Errorf("Expected default value true, got %v", result)
		}

		// Test with non-existent variable
		result = GetEnv("NON_EXISTENT_BOOL", true)
		if result != true {
			t.Errorf("Expected default value true, got %v", result)
		}
	})

	t.Run("Integer", func(t *testing.T) {
		// Test valid integer
		os.Setenv("TEST_INT", "42")
		defer os.Unsetenv("TEST_INT")
		result := GetEnv("TEST_INT", 0)
		if result != 42 {
			t.Errorf("Expected 42, got %d", result)
		}

		// Test negative integer
		os.Setenv("TEST_INT_NEG", "-42")
		defer os.Unsetenv("TEST_INT_NEG")
		result = GetEnv("TEST_INT_NEG", 0)
		if result != -42 {
			t.Errorf("Expected -42, got %d", result)
		}

		// Test with invalid integer
		os.Setenv("TEST_INT_INVALID", "not-an-int")
		defer os.Unsetenv("TEST_INT_INVALID")
		result = GetEnv("TEST_INT_INVALID", 99)
		if result != 99 {
			t.Errorf("Expected default value 99, got %d", result)
		}

		// Test with non-existent variable
		result = GetEnv("NON_EXISTENT_INT", 99)
		if result != 99 {
			t.Errorf("Expected default value 99, got %d", result)
		}
	})

	t.Run("Int64", func(t *testing.T) {
		// Test valid int64
		os.Setenv("TEST_INT64", "9223372036854775807") // Max int64
		defer os.Unsetenv("TEST_INT64")
		result := GetEnv("TEST_INT64", int64(0))
		if result != int64(9223372036854775807) {
			t.Errorf("Expected 9223372036854775807, got %d", result)
		}

		// Test with invalid int64
		os.Setenv("TEST_INT64_INVALID", "not-an-int64")
		defer os.Unsetenv("TEST_INT64_INVALID")
		result = GetEnv("TEST_INT64_INVALID", int64(99))
		if result != int64(99) {
			t.Errorf("Expected default value 99, got %d", result)
		}
	})

	t.Run("Float", func(t *testing.T) {
		// Test valid float
		os.Setenv("TEST_FLOAT", "3.14159")
		defer os.Unsetenv("TEST_FLOAT")
		result := GetEnv("TEST_FLOAT", 0.0)
		if result != 3.14159 {
			t.Errorf("Expected 3.14159, got %f", result)
		}

		// Test negative float
		os.Setenv("TEST_FLOAT_NEG", "-2.718")
		defer os.Unsetenv("TEST_FLOAT_NEG")
		result = GetEnv("TEST_FLOAT_NEG", 0.0)
		if result != -2.718 {
			t.Errorf("Expected -2.718, got %f", result)
		}

		// Test with invalid float
		os.Setenv("TEST_FLOAT_INVALID", "not-a-float")
		defer os.Unsetenv("TEST_FLOAT_INVALID")
		result = GetEnv("TEST_FLOAT_INVALID", 99.9)
		if result != 99.9 {
			t.Errorf("Expected default value 99.9, got %f", result)
		}

		// Test with non-existent variable
		result = GetEnv("NON_EXISTENT_FLOAT", 99.9)
		if result != 99.9 {
			t.Errorf("Expected default value 99.9, got %f", result)
		}
	})

	t.Run("StringSlice", func(t *testing.T) {
		// Test valid string slice
		os.Setenv("TEST_STRING_SLICE", "item1,item2,item3")
		defer os.Unsetenv("TEST_STRING_SLICE")
		result := GetEnv("TEST_STRING_SLICE", []string{"default"})
		expected := []string{"item1", "item2", "item3"}
		
		if len(result) != len(expected) {
			t.Errorf("Expected slice length %d, got %d", len(expected), len(result))
		} else {
			for i, v := range expected {
				if result[i] != v {
					t.Errorf("Expected %s at index %d, got %s", v, i, result[i])
				}
			}
		}

		// Test with spaces
		os.Setenv("TEST_STRING_SLICE_SPACES", "item1, item2, item3")
		defer os.Unsetenv("TEST_STRING_SLICE_SPACES")
		result = GetEnv("TEST_STRING_SLICE_SPACES", []string{"default"})
		
		if len(result) != len(expected) {
			t.Errorf("Expected slice length %d, got %d", len(expected), len(result))
		} else {
			for i, v := range expected {
				if result[i] != v {
					t.Errorf("Expected %s at index %d, got %s", v, i, result[i])
				}
			}
		}

		// Test with non-existent variable
		defaultSlice := []string{"default1", "default2"}
		result = GetEnv("NON_EXISTENT_SLICE", defaultSlice)
		if len(result) != len(defaultSlice) {
			t.Errorf("Expected slice length %d, got %d", len(defaultSlice), len(result))
		} else {
			for i, v := range defaultSlice {
				if result[i] != v {
					t.Errorf("Expected %s at index %d, got %s", v, i, result[i])
				}
			}
		}
	})

	t.Run("Duration", func(t *testing.T) {
		// Test valid duration
		os.Setenv("TEST_DURATION", "5m30s")
		defer os.Unsetenv("TEST_DURATION")
		result := GetEnv("TEST_DURATION", time.Duration(0))
		expected := 5*time.Minute + 30*time.Second
		if result != expected {
			t.Errorf("Expected duration %v, got %v", expected, result)
		}

		// Test with invalid duration
		os.Setenv("TEST_DURATION_INVALID", "not-a-duration")
		defer os.Unsetenv("TEST_DURATION_INVALID")
		defaultDuration := 10 * time.Second
		result = GetEnv("TEST_DURATION_INVALID", defaultDuration)
		if result != defaultDuration {
			t.Errorf("Expected default duration %v, got %v", defaultDuration, result)
		}
	})

	t.Run("UnsupportedType", func(t *testing.T) {
		// Test with an unsupported type (struct)
		type testStruct struct {
			Value string
		}
		
		os.Setenv("TEST_STRUCT", "some-value")
		defer os.Unsetenv("TEST_STRUCT")
		
		defaultValue := testStruct{Value: "default"}
		result := GetEnv("TEST_STRUCT", defaultValue)
		
		if result.Value != defaultValue.Value {
			t.Errorf("Expected default struct value %v, got %v", defaultValue, result)
		}
	})
}

// TestGetEnvRealWorld tests the function with real-world use cases
func TestGetEnvRealWorld(t *testing.T) {
	// Test USE_FIRECRACKER_NATIVE_DIFF flag
	t.Run("FirecrackerNativeDiff", func(t *testing.T) {
		// Test with flag enabled
		os.Setenv("USE_FIRECRACKER_NATIVE_DIFF", "true")
		defer os.Unsetenv("USE_FIRECRACKER_NATIVE_DIFF")
		
		useFirecrackerNativeDiff := GetEnv("USE_FIRECRACKER_NATIVE_DIFF", false)
		if !useFirecrackerNativeDiff {
			t.Errorf("Expected USE_FIRECRACKER_NATIVE_DIFF to be true, got false")
		}
		
		// Test with flag disabled
		os.Setenv("USE_FIRECRACKER_NATIVE_DIFF", "false")
		useFirecrackerNativeDiff = GetEnv("USE_FIRECRACKER_NATIVE_DIFF", true)
		if useFirecrackerNativeDiff {
			t.Errorf("Expected USE_FIRECRACKER_NATIVE_DIFF to be false, got true")
		}
		
		// Test with flag not set (should use default)
		os.Unsetenv("USE_FIRECRACKER_NATIVE_DIFF")
		useFirecrackerNativeDiff = GetEnv("USE_FIRECRACKER_NATIVE_DIFF", false)
		if useFirecrackerNativeDiff {
			t.Errorf("Expected USE_FIRECRACKER_NATIVE_DIFF to be false (default), got true")
		}
	})
	
	// Test port configuration
	t.Run("Port", func(t *testing.T) {
		os.Setenv("PORT", "8080")
		defer os.Unsetenv("PORT")
		
		port := GetEnv("PORT", 3000)
		if port != 8080 {
			t.Errorf("Expected PORT to be 8080, got %d", port)
		}
	})
	
	// Test timeout configuration
	t.Run("Timeout", func(t *testing.T) {
		os.Setenv("TIMEOUT", "30s")
		defer os.Unsetenv("TIMEOUT")
		
		timeout := GetEnv("TIMEOUT", 5*time.Second)
		if timeout != 30*time.Second {
			t.Errorf("Expected TIMEOUT to be 30s, got %v", timeout)
		}
	})
}
