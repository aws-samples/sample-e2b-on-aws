package exporter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/e2b-dev/infra/packages/envd/internal/timing"
)

const (
	mmdsDefaultAddress  = "169.254.169.254"
	mmdsTokenExpiration = 60 * time.Second
)

type opts struct {
	TraceID    string `json:"traceID"`
	InstanceID string `json:"instanceID"`
	EnvID      string `json:"envID"`
	Address    string `json:"address"`
	TeamID     string `json:"teamID"`
}

func (opts *opts) addOptsToJSON(jsonLogs []byte) ([]byte, error) {
	parsed := make(map[string]interface{})

	err := json.Unmarshal(jsonLogs, &parsed)
	if err != nil {
		return nil, err
	}

	parsed["instanceID"] = opts.InstanceID
	parsed["envID"] = opts.EnvID
	parsed["traceID"] = opts.TraceID
	parsed["teamID"] = opts.TeamID

	data, err := json.Marshal(parsed)

	return data, err
}

func (w *HTTPExporter) getMMDSToken(ctx context.Context) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, "http://"+mmdsDefaultAddress+"/latest/api/token", new(bytes.Buffer))
	if err != nil {
		return "", err
	}

	request.Header["X-metadata-token-ttl-seconds"] = []string{fmt.Sprint(mmdsTokenExpiration.Seconds())}

	response, err := w.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return "", err
	}

	token := string(body)

	if len(token) == 0 {
		return "", fmt.Errorf("mmds token is an empty string")
	}

	return token, nil
}

func (w *HTTPExporter) doMmdsRequest(ctx context.Context, token string) (*opts, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+mmdsDefaultAddress, new(bytes.Buffer))
	if err != nil {
		return nil, err
	}

	request.Header["X-metadata-token"] = []string{token}
	request.Header["Accept"] = []string{"application/json"}

	response, err := w.client.Do(request)
	if err != nil {
		return nil, err
	}

	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, err
	}

	var opts opts

	err = json.Unmarshal(body, &opts)
	if err != nil {
		return nil, err
	}

	return &opts, nil
}

func (w *HTTPExporter) waitForMMDS(ctx context.Context) {
	waitStart := time.Now()
	if timing.Enabled {
		fmt.Printf("[envd-timing] event=mmds_wait_start since_start=%s\n", timing.SinceStart())
	}

	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	attempts := 0

	for {
		select {
		case <-ctx.Done():
			if timing.Enabled {
				fmt.Printf("[envd-timing] event=mmds_wait_context_done attempts=%d duration=%s since_start=%s\n", attempts, time.Since(waitStart), timing.SinceStart())
			}
			return
		case <-ticker.C:
			attempts++
			token, err := w.getMMDSToken(ctx)
			if err != nil {
				if timing.Enabled && (attempts == 1 || attempts%20 == 0) {
					fmt.Printf("[envd-timing] event=mmds_token_error attempts=%d duration=%s since_start=%s err=%q\n", attempts, time.Since(waitStart), timing.SinceStart(), err.Error())
				}
				fmt.Printf("error getting mmds token: %v\n", err)
				continue
			}

			mmdsOpts, err := w.doMmdsRequest(ctx, token)
			if err != nil {
				if timing.Enabled && (attempts == 1 || attempts%20 == 0) {
					fmt.Printf("[envd-timing] event=mmds_opts_error attempts=%d duration=%s since_start=%s err=%q\n", attempts, time.Since(waitStart), timing.SinceStart(), err.Error())
				}
				fmt.Printf("error getting mmds opts: %v\n", err)
				continue
			}

			if mmdsOpts.Address != "" {
				if timing.Enabled {
					fmt.Printf("[envd-timing] event=mmds_wait_done attempts=%d duration=%s since_start=%s\n", attempts, time.Since(waitStart), timing.SinceStart())
				}
				return
			}
		}
	}
}

func (w *HTTPExporter) getMMDSOpts(ctx context.Context, token string) (opts *opts, err error) {
	opts, err = w.doMmdsRequest(ctx, token)
	if err != nil {
		return nil, err
	}

	if opts.Address == "" {
		return nil, fmt.Errorf("no 'address' in mmds opts")
	}

	if opts.EnvID == "" {
		return nil, fmt.Errorf("no 'envID' in mmds opts")
	}

	if opts.InstanceID == "" {
		return nil, fmt.Errorf("no 'instanceID' in mmds opts")
	}

	return opts, nil
}
