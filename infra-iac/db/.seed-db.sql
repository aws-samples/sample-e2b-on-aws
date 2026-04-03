-- seed-db.sql
-- Hash-based token storage aligned with upstream e2b-dev/infra
-- Triggers are disabled to avoid auto-generation conflicts

BEGIN;

SET session_replication_role = 'replica';

-- 1. Create user in public.users
CREATE TEMP TABLE temp_new_user (id uuid);
WITH new_user AS (
    INSERT INTO public.users (id, email)
    VALUES (gen_random_uuid(), :'email')
    RETURNING id
)
INSERT INTO temp_new_user SELECT id FROM new_user;

-- 2. Create team
INSERT INTO teams (id, name, email, tier, created_at, slug)
VALUES (
    :'teamID'::uuid, 'E2B', :'email', 'base_v1', CURRENT_TIMESTAMP,
    LOWER(REGEXP_REPLACE(SPLIT_PART(:'email', '@', 1), '[^a-zA-Z0-9]', '-', 'g'))
);

-- 3. Link user to team
--    uuid_id is the UUID primary key (after migration 20260316120000)
--    id (bigint) is auto-generated
INSERT INTO users_teams (uuid_id, is_default, user_id, team_id)
SELECT gen_random_uuid(), true, id, :'teamID'::uuid
FROM temp_new_user;

-- 4. Create access token (hash-only, no plaintext in DB)
INSERT INTO access_tokens (
    id, user_id,
    access_token_hash, access_token_prefix, access_token_length,
    access_token_mask_prefix, access_token_mask_suffix,
    name, created_at
)
SELECT
    gen_random_uuid(), id,
    :'accessTokenHash', 'sk_e2b_', 40,
    :'atMaskPrefix', :'atMaskSuffix',
    'Default Access Token', CURRENT_TIMESTAMP
FROM temp_new_user;

-- 5. Create team API key (hash-only, no plaintext in DB)
INSERT INTO team_api_keys (
    id, team_id,
    api_key_hash, api_key_prefix, api_key_length,
    api_key_mask_prefix, api_key_mask_suffix,
    name, created_at
)
VALUES (
    gen_random_uuid(), :'teamID'::uuid,
    :'apiKeyHash', 'e2b_', 40,
    :'akMaskPrefix', :'akMaskSuffix',
    'Default API Key', CURRENT_TIMESTAMP
);

-- 6. Create default environment
INSERT INTO envs (id, team_id, public, created_at, updated_at, build_count, spawn_count)
VALUES ('rki5dems9wqfm4r03t7g', :'teamID'::uuid, true, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 0);

DROP TABLE temp_new_user;

COMMIT;

\echo 'Database seeded successfully'
