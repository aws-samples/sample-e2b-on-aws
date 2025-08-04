package proxy

import (
	"regexp"
	"strconv"
	"strings"
	
	"go.uber.org/zap"
)

// Regular expression to match sandbox ID pattern (alphanumeric characters)
var sandboxIDPattern = regexp.MustCompile(`^[a-zA-Z0-9]+`)

func ParseHost(host string) (sandboxID string, port uint64, err error) {
	zap.L().Info("ParseHost method called", 
		zap.String("input_host", host))
	
	hostParts := strings.Split(host, "-")
	if len(hostParts) < 2 {
		return "", 0, &ErrInvalidHost{}
	}

	sandboxPortString := hostParts[0]
	sandboxIDWithDomain := hostParts[1]
	
	// Method 1: Use regex to extract only alphanumeric characters from the beginning
	// This is more robust as it doesn't depend on domain structure
	matches := sandboxIDPattern.FindString(sandboxIDWithDomain)
	if matches == "" {
		zap.L().Error("Failed to extract sandboxID using regex", 
			zap.String("sandboxIDWithDomain", sandboxIDWithDomain))
		return "", 0, &ErrInvalidHost{}
	}
	sandboxID = matches
	
	// Method 2: Fallback - if regex fails, try the dot-split method
	// but only take the first part before any dot
	if sandboxID == "" {
		domainParts := strings.Split(sandboxIDWithDomain, ".")
		sandboxID = domainParts[0]
	}

	sandboxPort, err := strconv.ParseUint(sandboxPortString, 10, 64)
	if err != nil {
		return "", 0, &ErrInvalidSandboxPort{}
	}

	zap.L().Info("ParseHost method result", 
		zap.String("input_host", host),
		zap.String("extracted_sandboxId", sandboxID),
		zap.Uint64("extracted_port", sandboxPort),
		zap.String("sandboxIDWithDomain", sandboxIDWithDomain))

	return sandboxID, sandboxPort, nil
}
