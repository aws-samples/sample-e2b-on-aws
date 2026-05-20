package server

import (
	"os"

	"go.uber.org/zap"
)

var resumeTimingDebug = os.Getenv("E2B_RESUME_TIMING_DEBUG") == "true" || os.Getenv("E2B_RESUME_TIMING_DEBUG") == "1"

func logResumeTiming(message string, fields ...zap.Field) {
	if !resumeTimingDebug {
		return
	}

	zap.L().Info("resume timing "+message, fields...)
}
