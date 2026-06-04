package telemetry

import (
	"context"
	"os"
	"testing"

	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

func TestNewMeterExporterUsesDeltaTemporalityForCountersAndHistograms(t *testing.T) {
	restoreEnv := unsetEnvForTest(t, "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE")
	defer restoreEnv()

	exporter, err := NewMeterExporter(context.Background())
	if err != nil {
		t.Fatalf("NewMeterExporter() error = %v", err)
	}

	tests := []struct {
		name string
		kind sdkmetric.InstrumentKind
		want metricdata.Temporality
	}{
		{"counter", sdkmetric.InstrumentKindCounter, metricdata.DeltaTemporality},
		{"histogram", sdkmetric.InstrumentKindHistogram, metricdata.DeltaTemporality},
		{"observable counter", sdkmetric.InstrumentKindObservableCounter, metricdata.DeltaTemporality},
		{"up down counter", sdkmetric.InstrumentKindUpDownCounter, metricdata.CumulativeTemporality},
		{"observable up down counter", sdkmetric.InstrumentKindObservableUpDownCounter, metricdata.CumulativeTemporality},
		{"gauge", sdkmetric.InstrumentKindGauge, metricdata.CumulativeTemporality},
		{"observable gauge", sdkmetric.InstrumentKindObservableGauge, metricdata.CumulativeTemporality},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := exporter.Temporality(tt.kind); got != tt.want {
				t.Fatalf("Temporality(%s) = %v, want %v", tt.kind, got, tt.want)
			}
		})
	}
}

func unsetEnvForTest(t *testing.T, name string) func() {
	t.Helper()

	oldValue, hadValue := os.LookupEnv(name)
	if err := os.Unsetenv(name); err != nil {
		t.Fatalf("failed to unset %s: %v", name, err)
	}

	return func() {
		if hadValue {
			_ = os.Setenv(name, oldValue)
		} else {
			_ = os.Unsetenv(name)
		}
	}
}
