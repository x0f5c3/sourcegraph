package store

import (
	"time"

	"github.com/lib/pq"

	"github.com/sourcegraph/sourcegraph/internal/codeintel/policies/shared"
	"github.com/sourcegraph/sourcegraph/internal/database/basestore"
	"github.com/sourcegraph/sourcegraph/internal/database/dbutil"
)

func scanPolicy(s dbutil.Scanner) (policy shared.Policy, err error) {
	return policy, s.Scan(
		&policy.ID,
	)
}

var scanPolicies = basestore.NewSliceScanner(scanPolicy)

// scanConfigurationPolicies scans a slice of configuration policies from the return value of `*Store.query`.
var scanConfigurationPolicies = basestore.NewSliceScanner(scanConfigurationPolicy)

func scanConfigurationPolicy(s dbutil.Scanner) (configurationPolicy shared.ConfigurationPolicy, err error) {
	var repositoryPatterns []string
	var retentionDurationHours, indexCommitMaxAgeHours *int

	if err := s.Scan(
		&configurationPolicy.ID,
		&configurationPolicy.RepositoryID,
		pq.Array(&repositoryPatterns),
		&configurationPolicy.Name,
		&configurationPolicy.Type,
		&configurationPolicy.Pattern,
		&configurationPolicy.Protected,
		&configurationPolicy.RetentionEnabled,
		&retentionDurationHours,
		&configurationPolicy.RetainIntermediateCommits,
		&configurationPolicy.IndexingEnabled,
		&indexCommitMaxAgeHours,
		&configurationPolicy.IndexIntermediateCommits,
	); err != nil {
		return configurationPolicy, err
	}

	if len(repositoryPatterns) != 0 {
		configurationPolicy.RepositoryPatterns = &repositoryPatterns
	}
	if retentionDurationHours != nil {
		duration := time.Duration(*retentionDurationHours) * time.Hour
		configurationPolicy.RetentionDuration = &duration
	}
	if indexCommitMaxAgeHours != nil {
		duration := time.Duration(*indexCommitMaxAgeHours) * time.Hour
		configurationPolicy.IndexCommitMaxAge = &duration
	}
	return configurationPolicy, nil
}

// scanFirstConfigurationPolicy scans a slice of configuration policies from the return value of `*Store.query`
// and returns the first.
var scanFirstConfigurationPolicy = basestore.NewFirstScanner(scanConfigurationPolicy)
