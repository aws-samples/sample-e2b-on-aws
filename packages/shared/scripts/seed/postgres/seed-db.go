package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/e2b-dev/infra/packages/shared/pkg/db"
	"github.com/e2b-dev/infra/packages/shared/pkg/keys"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/accesstoken"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/team"
)

func main() {
	ctx := context.Background()
	hasher := keys.NewSHA256Hashing()

	// Connect to database
	database, err := db.NewClient(1, 1)
	if err != nil {
		panic(err)
	}
	defer database.Close()

	// Check if database already has data
	count, err := database.Client.Team.Query().Count(ctx)
	if err != nil {
		panic(err)
	}

	if count > 1 {
		panic("Database contains some non-trivial data.")
	}

	// Define hardcoded values
	email := "user@example.com"
	teamUUID := uuid.MustParse("11111111-1111-1111-1111-111111111111")
	userUUID := uuid.MustParse("22222222-2222-2222-2222-222222222222")
	accessToken := "at_0123456789abcdef0123456789abcdef"
	teamAPIKey := "sk_fedcba9876543210fedcba9876543210"

	// First delete any existing data to avoid conflicts
	_, err = database.Client.Team.Delete().Where(team.Email(email)).Exec(ctx)
	if err != nil {
		fmt.Println("Warning: Could not delete team:", err)
	}

	// Delete any existing access tokens for this user ID if it exists
	_, err = database.Client.AccessToken.Delete().Where(accesstoken.UserIDEQ(userUUID)).Exec(ctx)
	if err != nil {
		fmt.Println("Warning: Could not delete access tokens:", err)
	}

	// Create user
	user, err := database.Client.User.Create().
		SetEmail(email).
		SetID(userUUID).
		Save(ctx)
	if err != nil {
		panic(err)
	}

	// Create team
	t, err := database.Client.Team.Create().
		SetEmail(email).
		SetName("E2B").
		SetID(teamUUID).
		SetTier("base_v1").
		Save(ctx)
	if err != nil {
		panic(err)
	}

	// Create user team relationship
	_, err = database.Client.UsersTeams.Create().
		SetUserID(user.ID).
		SetTeamID(t.ID).
		SetIsDefault(true).
		Save(ctx)
	if err != nil {
		panic(err)
	}

	// Create access token
	tokenWithoutPrefix := strings.TrimPrefix(accessToken, keys.AccessTokenPrefix)
	accessTokenBytes, err := hex.DecodeString(tokenWithoutPrefix)
	if err != nil {
		panic(err)
	}
	accessTokenHash := hasher.Hash(accessTokenBytes)
	accessTokenMask, err := keys.MaskKey(keys.AccessTokenPrefix, tokenWithoutPrefix)
	if err != nil {
		panic(err)
	}
	_, err = database.Client.AccessToken.Create().
		SetUser(user).
		SetAccessToken(accessToken).
		SetAccessTokenHash(accessTokenHash).
		SetAccessTokenPrefix(accessTokenMask.Prefix).
		SetAccessTokenLength(accessTokenMask.ValueLength).
		SetAccessTokenMaskPrefix(accessTokenMask.MaskedValuePrefix).
		SetAccessTokenMaskSuffix(accessTokenMask.MaskedValueSuffix).
		SetName("Seed Access Token").
		Save(ctx)
	if err != nil {
		panic(err)
	}

	// Create team API key
	keyWithoutPrefix := strings.TrimPrefix(teamAPIKey, keys.ApiKeyPrefix)
	teamApiKeyBytes, err := hex.DecodeString(keyWithoutPrefix)
	if err != nil {
		panic(err)
	}
	apiKeyHash := hasher.Hash(teamApiKeyBytes)
	apiKeyMask, err := keys.MaskKey(keys.ApiKeyPrefix, keyWithoutPrefix)
	if err != nil {
		panic(err)
	}
	_, err = database.Client.TeamAPIKey.Create().
		SetTeam(t).
		SetAPIKey(teamAPIKey).
		SetAPIKeyHash(apiKeyHash).
		SetAPIKeyPrefix(apiKeyMask.Prefix).
		SetAPIKeyLength(apiKeyMask.ValueLength).
		SetAPIKeyMaskPrefix(apiKeyMask.MaskedValuePrefix).
		SetAPIKeyMaskSuffix(apiKeyMask.MaskedValueSuffix).
		SetName("Seed API Key").
		Save(ctx)
	if err != nil {
		panic(err)
	}

	// Create template
	_, err = database.Client.Env.Create().
		SetTeam(t).
		SetID("rki5dems9wqfm4r03t7g").
		SetPublic(true).
		Save(ctx)
	if err != nil {
		panic(err)
	}

	fmt.Printf("Database seeded successfully.\n")
}
