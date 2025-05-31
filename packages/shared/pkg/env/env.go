package env

import (
	"os"
	"strconv"
	"strings"
	"time"
)

var environment = GetEnv("ENVIRONMENT", "local")

func IsProduction() bool {
	return environment == "prod"
}

func IsLocal() bool {
	return environment == "local"
}

func IsDevelopment() bool {
	return environment == "dev" || environment == "local"
}

func IsDebug() bool {
	return GetEnv("E2B_DEBUG", "false") == "true"
}

// GetEnv reads an environment variable and converts it to the specified type T.
// If the environment variable is not set or cannot be parsed, it returns the provided default value.
func GetEnv[T any](key string, defaultValue T) T {
	val := os.Getenv(key)
	if val == "" {
		return defaultValue
	}

	var result T
	switch any(defaultValue).(type) {
	case bool:
		boolVal, err := strconv.ParseBool(val)
		if err != nil {
			return defaultValue
		}
		result = any(boolVal).(T)
	case int:
		intVal, err := strconv.Atoi(val)
		if err != nil {
			return defaultValue
		}
		result = any(intVal).(T)
	case int64:
		intVal, err := strconv.ParseInt(val, 10, 64)
		if err != nil {
			return defaultValue
		}
		result = any(intVal).(T)
	case float64:
		floatVal, err := strconv.ParseFloat(val, 64)
		if err != nil {
			return defaultValue
		}
		result = any(floatVal).(T)
	case string:
		result = any(val).(T)
	case []string:
		// Handle comma-separated strings
		parts := strings.Split(val, ",")
		for i, part := range parts {
			parts[i] = strings.TrimSpace(part)
		}
		result = any(parts).(T)
	case time.Duration:
		duration, err := time.ParseDuration(val)
		if err != nil {
			return defaultValue
		}
		result = any(duration).(T)
	default:
		// For unsupported types, return the default value
		return defaultValue
	}

	return result
}
