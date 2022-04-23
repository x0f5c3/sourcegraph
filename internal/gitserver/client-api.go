package gitserver

import (
	"context"
	"net/http"
	"time"

	"github.com/sourcegraph/sourcegraph/internal/api"
	"github.com/sourcegraph/sourcegraph/internal/gitserver/protocol"
)

type ClientAPI interface {
	RequestRepoUpdate(ctx context.Context, repo api.RepoName, since time.Duration) (*protocol.RepoUpdateResponse, error)
	RepoInfo(ctx context.Context, repos ...api.RepoName) (*protocol.RepoInfoResponse, error)
	Remove(ctx context.Context, repo api.RepoName) error
	ResolveRevisions(ctx context.Context, repo api.RepoName, revs []protocol.RevisionSpecifier) ([]string, error)
}

type ClientService struct {
	http.Client
}

func NewClientService() ClientAPI {
	return &ClientService{}
}

func (s *ClientService) RequestRepoUpdate(ctx context.Context, repo api.RepoName, since time.Duration) (*protocol.RepoUpdateResponse, error) {
	// Do network API call
	return nil, nil
}
func (s *ClientService) RepoInfo(ctx context.Context, repos ...api.RepoName) (*protocol.RepoInfoResponse, error) {
	// Do network API call
	return nil, nil
}
func (s *ClientService) Remove(ctx context.Context, repo api.RepoName) error {
	// Do network API call
	return nil
}
func (s *ClientService) ResolveRevisions(ctx context.Context, repo api.RepoName, revs []protocol.RevisionSpecifier) ([]string, error) {
	// Do network API call
	return nil, nil
}
