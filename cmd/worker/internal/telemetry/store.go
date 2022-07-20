package telemetry

import (
	"context"

	"github.com/keegancsmith/sqlf"

	"github.com/sourcegraph/sourcegraph/internal/usagestats"

	"github.com/sourcegraph/sourcegraph/internal/database"
	"github.com/sourcegraph/sourcegraph/internal/database/basestore"
)

// Store is the interface over the out-of-band migrations tables.
type Store struct {
	*basestore.Store
}

func (s *Store) Events(ctx context.Context, after, count int) ([]usagestats.Event, error) {
	s.Query(ctx, sqlf.Sprintf("select * from event_logs"))
	return nil, nil
}

func (s *Store) SetBookmark(ctx context.Context, value int) error {
	// TODO implement me
	panic("implement me")
}

func (s *Store) GetBookmark(ctx context.Context) (int, error) {
	// TODO implement me
	panic("implement me")
}

type TelemetryStore interface {
	basestore.ShareableStore

	Events(ctx context.Context, after, count int) ([]usagestats.Event, error)
	SetBookmark(ctx context.Context, value int) error
	GetBookmark(ctx context.Context) (int, error)
}

// NewStoreWithDB creates a new TelemetryStore with the given database connection.
func NewStoreWithDB(db database.DB) *Store {
	return &Store{Store: basestore.NewWithHandle(db.Handle())}
}

var _ TelemetryStore = &Store{}

// With creates a new store with the underlying database handle from the given store.
// This method should be used when two distinct store instances need to perform an
// operation within the same shared transaction.
//
// This method wraps the basestore.With method.
func (s *Store) With(other basestore.ShareableStore) *Store {
	return &Store{Store: s.Store.With(other)}
}

// Transact returns a new store whose methods operate within the context of a new transaction
// or a new savepoint. This method will return an error if the underlying connection cannot be
// interface upgraded to a TxBeginner.
//
// This method wraps the basestore.Transact method.
func (s *Store) Transact(ctx context.Context) (*Store, error) {
	txBase, err := s.Store.Transact(ctx)
	return &Store{Store: txBase}, err
}
