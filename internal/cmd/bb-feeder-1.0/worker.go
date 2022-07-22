package main

import (
	"bytes"
	"context"
	"fmt"
	bbv1 "github.com/gfleury/go-bitbucket-v1"
	"github.com/prometheus/client_golang/prometheus"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/inconshreveable/log15"
	"github.com/schollz/progressbar/v3"
	"github.com/sourcegraph/sourcegraph/internal/ratelimit"
	"github.com/sourcegraph/sourcegraph/lib/errors"
)

func init() {
	rand.Seed(time.Now().UnixNano())
}

// randomOrgNameAndSize returns a random, unique name for an org and a random size of repos it should have
func randomOrgNameAndSize() (string, int) {
	size := rand.Intn(500)
	if size < 5 {
		size = 5
	}
	name := fmt.Sprintf("%s-%d", getRandomName(0), size)

	return name, size
}

// feederError is an error while processing an ownerRepo line. errType partitions the errors in 4 major categories
// to use in metrics in logging: api, clone, push and unknown.
type feederError struct {
	// one of: api, clone, push, unknown
	errType string
	// underlying error
	err error
}

func (e *feederError) Error() string {
	return fmt.Sprintf("%v: %v", e.errType, e.err)
}

func (e *feederError) Unwrap() error {
	return e.err
}

// worker processes ownerRepo strings, feeding them to bb instance. it declares orgs if needed, clones from
// github.com, adds bb as a remote, declares repo in bb through API and does a git push to the bb.
// there's many workers working at the same time, taking work from a work channel fed by a pump that reads lines
// from the input.
type worker struct {
	// used in logs and metrics
	name string
	// index of the worker (which one in range [0, numWorkers)
	index int
	// directory to use for cloning from github.com
	scratchDir string

	// BB API client
	client *bbv1.APIClient
	admin  string
	token  string

	// gets the lines of work from this channel (each line has a owner/repo string in some format)
	work <-chan string
	// wait group to decrement when this worker is done working
	wg *sync.WaitGroup
	// terminal UI progress bar
	bar *progressbar.ProgressBar

	// some stats
	numFailed    int64
	numSucceeded int64

	// feeder DB is a sqlite DB, worker marks processed ownerRepos as successfully processed or failed
	fdr *feederDB
	// keeps track of org to which to add repos
	// (when currentNumRepos reaches currentMaxRepos, it generates a new random triple of these)
	currentProject  string
	currentNumRepos int
	currentMaxRepos int

	// logger has worker name inprinted
	logger log15.Logger

	// rate limiter for the bb API calls
	rateLimiter *ratelimit.InstrumentedLimiter
	// how many simultaneous `git push` operations to the bb
	pushSem chan struct{}
	// how many simultaneous `git clone` operations from github.com
	cloneSem chan struct{}
	// how many times to try to clone from github.com
	numCloningAttempts int
	// how long to wait before cutting short a cloning from github.com
	cloneRepoTimeout time.Duration

	// host to add as a remote to a cloned repo pointing to bb instance
	host string
}

// run spins until work channel closes or context cancels
func (wkr *worker) run(ctx context.Context) {
	defer wkr.wg.Done()
	wkr.currentProject, wkr.currentMaxRepos = randomOrgNameAndSize()

	wkr.logger.Debug("switching to project", "project", wkr.currentProject)

	err := wkr.addBBProject(ctx)
	if err != nil {
		wkr.logger.Error("failed to create project", "project", wkr.currentProject, "error", err)
		// add it to default org then
		wkr.currentProject = ""
	} else {
		err = wkr.fdr.declareOrg(wkr.currentProject)
		if err != nil {
			wkr.logger.Error("failed to declare project", "project", wkr.currentProject, "error", err)
		}
	}

	for line := range wkr.work {
		_ = wkr.bar.Add(1)

		if ctx.Err() != nil {
			return
		}

		xs := strings.Split(line, "/")
		if len(xs) != 2 {
			wkr.logger.Error("failed tos split line", "line", line)
			continue
		}
		owner, repo := xs[0], xs[1]

		// process one owner/repo
		err := wkr.process(ctx, owner, repo)
		reposProcessedCounter.With(prometheus.Labels{"worker": wkr.name}).Inc()
		remainingWorkGauge.Add(-1.0)
		if err != nil {
			wkr.numFailed++
			errType := "unknown"
			var e *feederError
			if errors.As(err, &e) {
				errType = e.errType
			}
			reposFailedCounter.With(prometheus.Labels{"worker": wkr.name, "err_type": errType}).Inc()
			_ = wkr.fdr.failed(line, errType)
		} else {
			reposSucceededCounter.Inc()
			wkr.numSucceeded++
			wkr.currentNumRepos++

			err = wkr.fdr.succeeded(line, wkr.currentProject)
			if err != nil {
				wkr.logger.Error("failed to mark succeeded repo", "ownerRepo", line, "error", err)
			}

			// switch to a new org
			if wkr.currentNumRepos >= wkr.currentMaxRepos {
				wkr.currentProject, wkr.currentMaxRepos = randomOrgNameAndSize()
				wkr.currentNumRepos = 0
				wkr.logger.Debug("switching to org", "org", wkr.currentProject)
				err := wkr.addBBProject(ctx)
				if err != nil {
					wkr.logger.Error("failed to create org", "org", wkr.currentProject, "error", err)
					// add it to default org then
					wkr.currentProject = ""
				} else {
					err = wkr.fdr.declareOrg(wkr.currentProject)
					if err != nil {
						wkr.logger.Error("failed to declare org", "org", wkr.currentProject, "error", err)
					}
				}
			}
		}
		ownerDir := filepath.Join(wkr.scratchDir, owner)

		// clean up clone on disk
		err = os.RemoveAll(ownerDir)
		if err != nil {
			wkr.logger.Error("failed to clean up cloned repo", "ownerRepo", line, "error", err, "ownerDir", ownerDir)
		}
	}
}

// process does the necessary work for one ownerRepo string: clone, declare repo in bb through API, add remote and push
func (wkr *worker) process(ctx context.Context, owner, repo string) error {
	start := time.Now()

	err := wkr.cloneRepo(ctx, owner, repo)
	if err != nil {
		wkr.logger.Error("failed to clone repo", "owner", owner, "repo", repo, "error", err)
		return &feederError{"clone", err}
	}
	t := time.Now()
	elapsed := t.Sub(start).Minutes()
	wkr.logger.Info(fmt.Sprintf("cloneRepo took: %f minutes.\n", elapsed), "owner", owner, "repo", repo)

	bbRepo, err := wkr.addBBRepo(ctx, wkr.currentProject, repo)
	start = time.Now()
	if err != nil {
		wkr.logger.Error("failed to create bb repo", "owner", owner, "repo", repo, "error", err)
		return &feederError{"api", err}
	}
	t = time.Now()
	elapsed = t.Sub(start).Minutes()
	wkr.logger.Info(fmt.Sprintf("addBBRepo took: %f minutes.\n", elapsed), "owner", owner, "repo", repo)

	err = wkr.addRemote(ctx, bbRepo, owner, repo)
	start = time.Now()
	if err != nil {
		wkr.logger.Error("failed to add bb as a remote in cloned repo", "owner", owner, "repo", repo, "error", err)
		return &feederError{"api", err}
	}
	t = time.Now()
	elapsed = t.Sub(start).Minutes()
	wkr.logger.Info(fmt.Sprintf("addRemote took: %f minutes.\n", elapsed), "owner", owner, "repo", repo)

	start = time.Now()
	for attempt := 0; attempt < wkr.numCloningAttempts && ctx.Err() == nil; attempt++ {
		startAttempt := time.Now()
		wkr.logger.Info(fmt.Sprintf("pushToBB attempt %v starts at %v", attempt+1, startAttempt))
		err = wkr.pushToBB(ctx, owner, repo)
		endAttempt := time.Now()
		wkr.logger.Info(fmt.Sprintf("pushToBB attempt %v ends at %v", attempt+1, endAttempt))
		tAttempt := time.Now()
		elapsedAttempt := tAttempt.Sub(startAttempt).Minutes()
		wkr.logger.Info(fmt.Sprintf("pushToBB Attempt %d took: %f minutes.\n", attempt+1, elapsedAttempt), "owner", owner, "repo", repo)

		if err == nil {
			return nil
		}
		wkr.logger.Error("failed to push cloned repo to bb", "attempt", attempt+1, "owner", owner, "repo", repo, "error", err)
	}
	t = time.Now()
	elapsed = t.Sub(start).Minutes()
	wkr.logger.Info(fmt.Sprintf("pushToBB took: %f minutes.\n", elapsed), "owner", owner, "repo", repo)

	return &feederError{"push", err}
}

// cloneRepo clones the specified repo from github.com into the scratchDir
func (wkr *worker) cloneRepo(ctx context.Context, owner, repo string) error {
	select {
	case wkr.cloneSem <- struct{}{}:
		defer func() {
			<-wkr.cloneSem
		}()

		ownerDir := filepath.Join(wkr.scratchDir, owner)
		err := os.MkdirAll(ownerDir, 0777)
		if err != nil {
			wkr.logger.Error("failed to create owner dir", "ownerDir", ownerDir, "error", err)
			return err
		}

		ctx, cancel := context.WithTimeout(ctx, wkr.cloneRepoTimeout)
		defer cancel()

		cmd := exec.CommandContext(ctx, "git", "clone",
			fmt.Sprintf("https://github.com/%s/%s", owner, repo))
		cmd.Dir = ownerDir
		cmd.Env = append(cmd.Env, "GIT_ASKPASS=/bin/echo")

		return cmd.Run()
	case <-ctx.Done():
		return ctx.Err()
	}
}

// addRemote declares the bb as a remote to the cloned repo
func (wkr *worker) addRemote(ctx context.Context, bbRepo *bbv1.Repository, owner, repo string) error {
	repoDir := filepath.Join(wkr.scratchDir, owner, repo)

	remoteURL := fmt.Sprintf("http://%s/scm/%s/%s.git", wkr.host, wkr.currentProject, bbRepo.Slug)

	cmd := exec.CommandContext(ctx, "git", "remote", "add", "bb", remoteURL)
	cmd.Dir = repoDir

	return cmd.Run()
}

// pushToBB does a `git push` command to the BB remote
func (wkr *worker) pushToBB(ctx context.Context, owner, repo string) error {

	select {
	case wkr.pushSem <- struct{}{}:
		defer func() {
			<-wkr.pushSem
		}()
		repoDir := filepath.Join(wkr.scratchDir, owner, repo)

		ctx, cancel := context.WithTimeout(ctx, wkr.cloneRepoTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, "git", "push", "-u", "bb", "HEAD:master")
		cmd.Dir = repoDir

		var out bytes.Buffer
		var stderr bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &stderr
		errCmd := cmd.Run()
		if errCmd != nil {
			fmt.Println(fmt.Sprint(errCmd) + ": " + stderr.String())
			return errCmd
		}
		return errCmd
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (wkr *worker) addBBProject(ctx context.Context) error {
	err := wkr.rateLimiter.Wait(ctx)
	if err != nil {
		wkr.logger.Error("failed to get a request spot from rate limiter", "error", err)
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, time.Second*30)
	defer cancel()

	bbProject := bbv1.Project{Key: wkr.currentProject, Name: wkr.currentProject}

	_, err = wkr.client.DefaultApi.CreateProject(bbProject)

	return err
}

// addBBRepo uses the BB API to declare the repo at the BB
func (wkr *worker) addBBRepo(ctx context.Context, project, repo string) (*bbv1.Repository, error) {
	err := wkr.rateLimiter.Wait(ctx)
	if err != nil {
		wkr.logger.Error("failed to get a request spot from rate limiter", "error", err)
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, time.Second*30)
	defer cancel()

	bbProject := bbv1.Project{Key: project, Name: project}

	bbRepo := bbv1.Repository{Project: &bbProject, Slug: repo, Name: repo}

	resp, err := wkr.client.DefaultApi.CreateRepository(project, bbRepo)
	repository, err := bbv1.GetRepositoryResponse(resp)
	if err != nil {
		wkr.logger.Error("failed to parse response to obtain Repository", "error", err)
		return nil, err
	}

	return &repository, nil
}
