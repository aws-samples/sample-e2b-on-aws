-- Upgrade Firecracker from v1.10.1 to v1.12.1 (align with upstream e2b-dev/infra stable)
-- Upgrade Guest Kernel from 6.1.102 to 6.1.158 (65 patches behind stable)
-- Note: Existing snapshots must be regenerated after this upgrade

-- +goose Up
-- +goose StatementBegin
ALTER TABLE env_builds ALTER COLUMN firecracker_version SET DEFAULT 'v1.12.1_210cbac';
ALTER TABLE env_builds ALTER COLUMN kernel_version SET DEFAULT 'vmlinux-6.1.158';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE env_builds ALTER COLUMN firecracker_version SET DEFAULT 'v1.7.0-dev_8bb88311';
ALTER TABLE env_builds ALTER COLUMN kernel_version SET DEFAULT 'vmlinux-5.10.186';
-- +goose StatementEnd
