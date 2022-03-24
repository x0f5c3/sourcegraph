package lockfiles

import (
	"context"
	"io"

	"github.com/sourcegraph/sourcegraph/internal/api"
	"github.com/sourcegraph/sourcegraph/internal/authz"
	"github.com/sourcegraph/sourcegraph/internal/gitserver"
	"github.com/sourcegraph/sourcegraph/internal/vcs/git"
)

type GitService interface {
	LsFiles(ctx context.Context, repo api.RepoName, commits api.CommitID, pathspecs ...gitserver.Pathspec) ([]string, error)
	Archive(ctx context.Context, repo api.RepoName, opts gitserver.ArchiveOptions) (io.ReadCloser, error)
}

type gitService struct {
	checker authz.SubRepoPermissionChecker
}

func NewDefaultGitService(checker authz.SubRepoPermissionChecker) GitService {
	if checker == nil {
		checker = authz.DefaultSubRepoPermsChecker
	}

	return &gitService{
		checker: checker,
	}
}

func (s *gitService) LsFiles(ctx context.Context, repo api.RepoName, commits api.CommitID, pathspecs ...gitserver.Pathspec) ([]string, error) {
	return git.LsFiles(ctx, s.checker, repo, commits, pathspecs...)
}

func (s *gitService) Archive(ctx context.Context, repo api.RepoName, opts gitserver.ArchiveOptions) (io.ReadCloser, error) {
	return git.ArchiveReader(ctx, repo, opts)
}
