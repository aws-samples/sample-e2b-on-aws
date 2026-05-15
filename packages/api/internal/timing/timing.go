package timing

import (
	"os"

	"go.uber.org/zap"
)

var ResumeDebug = os.Getenv("E2B_RESUME_TIMING_DEBUG") == "true" || os.Getenv("E2B_RESUME_TIMING_DEBUG") == "1"

func Log(message string, fields ...zap.Field) {
	if !ResumeDebug {
		return
	}

	zap.L().Info("resume timing "+message, fields...)
}
