package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/e2b-dev/infra/packages/envd/internal/host"
	"github.com/e2b-dev/infra/packages/envd/internal/logs"
	"github.com/e2b-dev/infra/packages/envd/internal/timing"
)

func (a *API) PostInit(w http.ResponseWriter, r *http.Request) {
	handlerStart := time.Now()
	defer r.Body.Close()

	operationID := logs.AssignOperationID()
	logger := a.logger.With().Str(string(logs.OperationIDKey), operationID).Logger()
	if timing.Enabled {
		logger.Info().
			Str("event_type", "envd_timing").
			Str("timing_event", "post_init_received").
			Dur("since_start", timing.SinceStart()).
			Msg("envd timing")
	}

	if r.Body != nil {
		var initRequest PostInitJSONBody

		decodeStart := time.Now()
		err := json.NewDecoder(r.Body).Decode(&initRequest)
		if timing.Enabled {
			logger.Info().
				Str("event_type", "envd_timing").
				Str("timing_event", "post_init_decode_done").
				Dur("duration", time.Since(decodeStart)).
				Dur("since_start", timing.SinceStart()).
				Msg("envd timing")
		}
		if err != nil && err != io.EOF {
			logger.Error().Msgf("Failed to decode request: %v", err)
			w.WriteHeader(http.StatusBadRequest)

			return
		}

		if initRequest.EnvVars != nil {
			envStart := time.Now()
			logger.Debug().Msg(fmt.Sprintf("Setting %d env vars", len(*initRequest.EnvVars)))

			for key, value := range *initRequest.EnvVars {
				logger.Debug().Msgf("Setting env var for %s", key)
				a.envVars.Store(key, value)
			}
			if timing.Enabled {
				logger.Info().
					Str("event_type", "envd_timing").
					Str("timing_event", "post_init_envs_set").
					Int("env_count", len(*initRequest.EnvVars)).
					Dur("duration", time.Since(envStart)).
					Dur("since_start", timing.SinceStart()).
					Msg("envd timing")
			}
		}

		if initRequest.AccessToken != nil {
			tokenStart := time.Now()
			if a.accessToken != nil && *initRequest.AccessToken != *a.accessToken {
				logger.Error().Msg("Access token is already set and cannot be changed")
				w.WriteHeader(http.StatusConflict)
				return
			}

			logger.Debug().Msg("Setting access token")
			a.accessToken = initRequest.AccessToken
			if timing.Enabled {
				logger.Info().
					Str("event_type", "envd_timing").
					Str("timing_event", "post_init_access_token_set").
					Dur("duration", time.Since(tokenStart)).
					Dur("since_start", timing.SinceStart()).
					Msg("envd timing")
			}
		}
	}

	logger.Debug().Msg("Syncing host")

	go func() {
		hostSyncStart := time.Now()
		if timing.Enabled {
			logger.Info().
				Str("event_type", "envd_timing").
				Str("timing_event", "host_sync_start").
				Dur("since_start", timing.SinceStart()).
				Msg("envd timing")
		}
		err := host.Sync()
		if err != nil {
			logger.Error().Msgf("Failed to sync clock: %v", err)
		} else {
			logger.Trace().Msg("Clock synced")
		}
		if timing.Enabled {
			logger.Info().
				Str("event_type", "envd_timing").
				Str("timing_event", "host_sync_done").
				Dur("duration", time.Since(hostSyncStart)).
				Dur("since_start", timing.SinceStart()).
				Err(err).
				Msg("envd timing")
		}
	}()

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "")

	responseStart := time.Now()
	w.WriteHeader(http.StatusNoContent)
	if timing.Enabled {
		logger.Info().
			Str("event_type", "envd_timing").
			Str("timing_event", "post_init_response_written").
			Dur("write_duration", time.Since(responseStart)).
			Dur("handler_duration", time.Since(handlerStart)).
			Dur("since_start", timing.SinceStart()).
			Msg("envd timing")
	}
}
