// generate_api_key.go generates a properly formatted E2B API key and outputs:
//   - The raw API key (for SDK / env config)
//   - The SQL INSERT statement with the SHA-256 hash (for database seeding)
//
// Usage:
//
//	go run generate_api_key.go
//	go run generate_api_key.go -team-id 00000000-0000-0000-0000-000000000001
//	go run generate_api_key.go -name "Production Key"
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/e2b-dev/infra/packages/shared/pkg/keys"
)

// sqlEscape escapes single quotes in a string for safe SQL interpolation.
func sqlEscape(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

func main() {
	teamID := flag.String("team-id", "00000000-0000-0000-0000-000000000001", "Team UUID for the API key")
	keyName := flag.String("name", "Default API Key", "Human-readable name for the API key")
	flag.Parse()

	// Generate a new API key using the upstream keys package.
	// This produces:
	//   - PrefixedRawValue: "e2b_" + 40 hex chars (20 random bytes)
	//   - HashedValue:      "$sha256$" + base64(sha256(raw_bytes))
	//   - Masked:           prefix, suffix for display masking
	key, err := keys.GenerateKey(keys.ApiKeyPrefix)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error generating key: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("=== E2B API Key Generated ===")
	fmt.Println()
	fmt.Printf("Raw API Key (save this -- it cannot be recovered):\n")
	fmt.Printf("  %s\n", key.PrefixedRawValue)
	fmt.Println()
	fmt.Printf("Hash (stored in database):\n")
	fmt.Printf("  %s\n", key.HashedValue)
	fmt.Println()
	fmt.Printf("Mask info:\n")
	fmt.Printf("  Prefix:      %s\n", key.Masked.Prefix)
	fmt.Printf("  Length:       %d\n", key.Masked.ValueLength)
	fmt.Printf("  Mask prefix:  %s\n", key.Masked.MaskedValuePrefix)
	fmt.Printf("  Mask suffix:  %s\n", key.Masked.MaskedValueSuffix)
	fmt.Println()
	fmt.Println("=== SQL INSERT (paste into seed.sql or run directly) ===")
	fmt.Println()
	fmt.Printf(`INSERT INTO public.team_api_keys (team_id, api_key_hash, api_key_prefix, api_key_length, api_key_mask_prefix, api_key_mask_suffix, name)
VALUES ('%s', '%s', '%s', %d, '%s', '%s', '%s');
`,
		sqlEscape(*teamID),
		sqlEscape(key.HashedValue),
		sqlEscape(key.Masked.Prefix),
		key.Masked.ValueLength,
		sqlEscape(key.Masked.MaskedValuePrefix),
		sqlEscape(key.Masked.MaskedValueSuffix),
		sqlEscape(*keyName),
	)
	fmt.Println()
	fmt.Println("=== Environment variable for tests/SDK ===")
	fmt.Println()
	fmt.Printf("export E2B_API_KEY=%s\n", key.PrefixedRawValue)
}
