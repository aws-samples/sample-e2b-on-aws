package main

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestVerifiedMigrationIsNewest fails when an upstream sync brings migrations
// this tool has not been verified against. That is deliberate: the fix is to
// re-run the tool as a dry run against a database at the new version, read the
// candidates it reports, and then set verifiedMigration to the value below.
func TestVerifiedMigrationIsNewest(t *testing.T) {
	entries, err := os.ReadDir("../../packages/db/migrations")
	if err != nil {
		t.Fatalf("read migrations: %v", err)
	}

	var newest int64
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".sql") {
			continue
		}
		prefix, _, _ := strings.Cut(name, "_")
		v, err := strconv.ParseInt(prefix, 10, 64)
		if err != nil {
			continue
		}
		newest = max(newest, v)
	}

	if newest == 0 {
		t.Fatal("no migrations found; is the vendored code layer present?")
	}
	if newest != verifiedMigration {
		t.Fatalf("packages/db/migrations now ends at %d but verifiedMigration is %d.\n"+
			"An upstream sync added migrations. Re-verify the queries in tools/snapshot-retention against a database at %d "+
			"(run the tool as a dry run and check its candidates), then set verifiedMigration = %d in schema.go.",
			newest, verifiedMigration, newest, newest)
	}
}
