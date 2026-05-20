package timing

import (
	"os"
	"time"
)

var (
	ForceEnabled = "false"
	Enabled      = ForceEnabled == "true" || os.Getenv("E2B_ENVD_TIMING_DEBUG") == "true" || os.Getenv("E2B_ENVD_TIMING_DEBUG") == "1"
	ProcessStart = time.Now()
)

func SinceStart() time.Duration {
	return time.Since(ProcessStart)
}
