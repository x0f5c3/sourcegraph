package telemetry

// const MAX_EVENTS_COUNT_DEFAULT = 5000 // todo setting
//
// func (t *telemetryHandler) Handle(ctx context.Context) error {
// 	// first check if we are still allowed to collect this telemetry
// 	// ie. has the value of the setting changed since we started up?
//
// 	// load the latest configuration for max event count, or default to above
//
// 	last, err := t.fetchBookmark(ctx)
// 	if err != nil {
// 		return err
// 	}
//
// 	// todo transaction
// 	events, err := t.fetchEvents(ctx, last, MAX_EVENTS_COUNT_DEFAULT)
// 	if err != nil {
// 		return err
// 	}
// 	if len(events) == 0 {
// 		return nil
// 	}
// 	if err = usagestats.PublishSourcegraphDotComEvents(events); err != nil {
// 		return err
// 	}
// 	newLast := *events[len(events)-1].EventID // todo verify this is the correct field
// 	if err := t.stampBookmark(ctx, int(newLast)); err != nil {
// 		return err
// 	}
//
// 	return nil
// }
//
// func (t *telemetryHandler) fetchBookmark(ctx context.Context) (int, error) {
//
// }
//
// func (t *telemetryHandler) stampBookmark(ctx context.Context, last int) error {
//
// }
//
// func (t *telemetryHandler) fetchEvents(ctx context.Context, after, count int) ([]usagestats.Event, error) {
//
// }
