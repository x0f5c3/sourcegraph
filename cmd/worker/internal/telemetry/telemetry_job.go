package telemetry

import (
	"context"
	"time"

	"github.com/sourcegraph/sourcegraph/internal/usagestats"

	workerdb "github.com/sourcegraph/sourcegraph/cmd/worker/shared/init/db"

	"github.com/opentracing/opentracing-go"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/sourcegraph/log"
	"github.com/sourcegraph/sourcegraph/internal/database"
	"github.com/sourcegraph/sourcegraph/internal/env"
	"github.com/sourcegraph/sourcegraph/internal/goroutine"
	"github.com/sourcegraph/sourcegraph/internal/observation"
	"github.com/sourcegraph/sourcegraph/internal/trace"
)

type telemetryJob struct{}

func (t *telemetryJob) Description() string {
	// TODO implement me
	panic("implement me")
}

func (t *telemetryJob) Config() []env.Config {
	// TODO implement me
	panic("implement me")
}

func (t *telemetryJob) Routines(ctx context.Context, logger log.Logger) ([]goroutine.BackgroundRoutine, error) {
	db, err := workerdb.Init()
	if err != nil {
		return nil, err
	}

	return []goroutine.BackgroundRoutine{
		NewTelemetryUploader(database.NewDB(logger, db)),
	}, nil
}

func NewTelemetryUploader(db database.DB) goroutine.BackgroundRoutine {

	observationContext := &observation.Context{
		Tracer:     &trace.Tracer{Tracer: opentracing.GlobalTracer()},
		Registerer: prometheus.NewRegistry(),
	}
	operation := observationContext.Operation(observation.Op{}) // todo

	return goroutine.NewPeriodicGoroutineWithMetrics(context.Background(), time.Minute*1, &telemetryHandler{}, operation)
}

type telemetryHandler struct {
	db database.DB
}

const MAX_EVENTS_COUNT_DEFAULT = 5000 // todo setting

func (t *telemetryHandler) Handle(ctx context.Context) error {
	// first check if we are still allowed to collect this telemetry
	// ie. has the value of the setting changed since we started up?

	// load the latest configuration for max event count, or default to above

	last, err := t.fetchBookmark(ctx)
	if err != nil {
		return err
	}

	// todo transaction
	events, err := t.fetchEvents(ctx, last, MAX_EVENTS_COUNT_DEFAULT)
	if err != nil {
		return err
	}
	if len(events) == 0 {
		return nil
	}
	if err = usagestats.PublishSourcegraphDotComEvents(events); err != nil {
		return err
	}
	newLast := *events[len(events)-1].EventID // todo verify this is the correct field
	if err := t.stampBookmark(ctx, int(newLast)); err != nil {
		return err
	}

	return nil
}

func (t *telemetryHandler) fetchBookmark(ctx context.Context) (int, error) {

}

func (t *telemetryHandler) stampBookmark(ctx context.Context, last int) error {

}

func (t *telemetryHandler) fetchEvents(ctx context.Context, after, count int) ([]usagestats.Event, error) {

}
