-- +goose Up
-- +goose StatementBegin
UPDATE public.tiers
SET disk_mb = 10240
WHERE id = 'base_v1';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
UPDATE public.tiers
SET disk_mb = 8192
WHERE id = 'base_v1';
-- +goose StatementEnd
