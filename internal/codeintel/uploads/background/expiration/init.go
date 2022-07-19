package expiration

import (
	"context"
	"fmt"

	"github.com/sourcegraph/log"

	"github.com/sourcegraph/sourcegraph/internal/goroutine"
)

func NewExpirer(uploadSvc UploadService, policySvc PolicyService, policyMatcher PolicyMatcher, metrics *metrics) goroutine.BackgroundRoutine {
	return goroutine.NewPeriodicGoroutine(context.Background(), ConfigInst.Interval, &expirer{
		uploadSvc:     uploadSvc,
		policySvc:     policySvc,
		policyMatcher: policyMatcher,
		metrics:       metrics,
		logger: log.Scoped("NewExpirer", "").With(
			log.String("uploadSvc", fmt.Sprintf("%v", uploadSvc)),
			log.String("policySvc", fmt.Sprintf("%v", policySvc)),
			log.String("policyMatcher", fmt.Sprintf("%v", policyMatcher)),
			log.String("metrics", fmt.Sprintf("%v", metrics)),
		),
	})
}
