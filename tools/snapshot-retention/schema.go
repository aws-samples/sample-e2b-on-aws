package main

import "context"

// verifiedMigration is the newest goose migration in packages/db/migrations
// that this tool's hand-written queries were checked against.
//
// The code layer is replaced wholesale on every upstream sync, and a migration
// can change what a column means without making any query here fail. So when
// the database has applied a newer migration than this, a run degrades to a dry
// run and exits non-zero until someone re-verifies the queries against the new
// schema and bumps this constant. TestVerifiedMigrationIsNewest fails as soon as
// a sync adds a migration, which turns that into a merge-time signal instead of
// a runtime one.
const verifiedMigration int64 = 20260826075153

// appliedMigration returns the newest goose version applied to the database.
// public._migrations is the table upstream's packages/db/Makefile and this
// deployment's infra-iac/db scripts use.
func (d *database) appliedMigration(ctx context.Context) (int64, error) {
	var version int64
	err := d.pool.QueryRow(ctx, `SELECT COALESCE(MAX(version_id), 0) FROM public._migrations WHERE is_applied`).Scan(&version)

	return version, err
}
