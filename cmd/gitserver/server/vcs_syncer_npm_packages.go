package server

import (
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"

	"github.com/sourcegraph/log"

	"github.com/sourcegraph/sourcegraph/internal/codeintel/dependencies"
	"github.com/sourcegraph/sourcegraph/internal/conf/reposource"
	"github.com/sourcegraph/sourcegraph/internal/extsvc/npm"
	"github.com/sourcegraph/sourcegraph/internal/unpack"
	"github.com/sourcegraph/sourcegraph/lib/errors"
	"github.com/sourcegraph/sourcegraph/schema"
)

// NewNpmPackagesSyncer create a new NpmPackageSyncer. If customClient is nil,
// the client for the syncer is configured based on the connection parameter.
func NewNpmPackagesSyncer(
	connection schema.NpmPackagesConnection,
	svc *dependencies.Service,
	client npm.Client,
) VCSSyncer {
	placeholder, err := reposource.ParseNpmVersionedPackage("@sourcegraph/placeholder@1.0.0")
	if err != nil {
		panic(fmt.Sprintf("expected placeholder package to parse but got %v", err))
	}

	return &vcsPackagesSyncer{
		logger:      log.Scoped("NPMPackagesSyncer", "sync NPM packages"),
		typ:         "npm_packages",
		scheme:      dependencies.NpmPackagesScheme,
		placeholder: placeholder,
		svc:         svc,
		configDeps:  connection.Dependencies,
		source:      &npmPackagesSyncer{client: client},
	}
}

type npmPackagesSyncer struct {
	// The client to use for making queries against npm.
	client npm.Client
}

var _ packagesSource = &npmPackagesSyncer{}
var _ packagesDownloadSource = &npmPackagesSyncer{}

func (npmPackagesSyncer) ParseVersionedPackageFromNameAndVersion(name, version string) (reposource.VersionedPackage, error) {
	return reposource.ParseNpmVersionedPackage(name + "@" + version)
}

func (npmPackagesSyncer) ParseVersionedPackageFromConfiguration(dep string) (reposource.VersionedPackage, error) {
	return reposource.ParseNpmVersionedPackage(dep)
}

func (s *npmPackagesSyncer) ParsePackageFromName(name string) (reposource.Package, error) {
	return s.ParsePackageFromRepoName("npm/" + strings.TrimPrefix(name, "@"))
}
func (npmPackagesSyncer) ParsePackageFromRepoName(repoName string) (reposource.Package, error) {
	pkg, err := reposource.ParseNpmPackageFromRepoURL(repoName)
	if err != nil {
		return nil, err
	}
	return &reposource.NpmVersionedPackage{NpmPackageName: pkg}, nil
}

func (s npmPackagesSyncer) GetPackage(ctx context.Context, name string) (reposource.Package, error) {
	dep, err := reposource.ParseNpmVersionedPackage(name + "@")
	if err != nil {
		return nil, err
	}

	err = s.UpdateTarballURL(ctx, dep)
	if err != nil {
		return nil, err
	}

	return dep, nil
}

func (s *npmPackagesSyncer) UpdateTarballURL(ctx context.Context, dep *reposource.NpmVersionedPackage) error {
	f, err := s.client.GetDependencyInfo(ctx, dep)
	if err != nil {
		return err
	}
	dep.TarballURL = f.Dist.TarballURL
	return nil
}

func (s *npmPackagesSyncer) Download(ctx context.Context, dir string, dep reposource.VersionedPackage) error {
	npmDep := dep.(*reposource.NpmVersionedPackage)
	if npmDep.TarballURL == "" {
		err := s.UpdateTarballURL(ctx, npmDep)
		if err != nil {
			return err
		}
	}
	tgz, err := npm.FetchSources(ctx, s.client, npmDep)
	if err != nil {
		return errors.Wrap(err, "fetch tarball")
	}
	defer tgz.Close()

	if err = decompressTgz(tgz, dir); err != nil {
		return errors.Wrapf(err, "failed to decompress gzipped tarball for %s", dep)
	}

	return nil
}

// Decompress a tarball at tgzPath, putting the files under destination.
//
// Additionally, if all the files in the tarball have paths of the form
// dir/<blah> for the same directory 'dir', the 'dir' will be stripped.
func decompressTgz(tgz io.Reader, destination string) error {
	logger := log.Scoped("decompressTgz", "Decompress a tarball at tgzPath, putting the files under destination.")
	err := unpack.Tgz(tgz, destination, unpack.Opts{
		SkipInvalid: true,
		Filter: func(path string, file fs.FileInfo) bool {
			size := file.Size()

			const sizeLimit = 15 * 1024 * 1024

			slogger := logger.With(
				log.String("path", file.Name()),
				log.Int64("size", size),
				log.Int("limit", sizeLimit),
			)

			if size >= sizeLimit {
				slogger.Warn("skipping large file in npm package")
				return false
			}

			_, malicious := isPotentiallyMaliciousFilepathInArchive(path, destination)
			return !malicious
		},
	})

	if err != nil {
		return err
	}

	return stripSingleOutermostDirectory(destination)
}

// stripSingleOutermostDirectory strips a single outermost directory in dir
// if it has no sibling files or directories.
//
// In practice, npm tarballs seem to contain a superfluous directory which
// contains the files. For example, if you extract react's tarball,
// all files will be under a package/ directory, and if you extract
// @types/lodash's files, all files are under lodash/.
//
// However, this additional directory has no meaning. Moreover, it makes
// the UX slightly worse, as when you navigate to a repo, you would see
// that it contains just 1 folder, and you'd need to click again to drill
// down further. So we strip the superfluous directory if we detect one.
//
// https://github.com/sourcegraph/sourcegraph/pull/28057#issuecomment-987890718
func stripSingleOutermostDirectory(dir string) error {
	dirEntries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}

	if len(dirEntries) != 1 || !dirEntries[0].IsDir() {
		return nil
	}

	outermostDir := dirEntries[0].Name()
	tmpDir := dir + ".tmp"

	// mv $dir $tmpDir
	err = os.Rename(dir, tmpDir)
	if err != nil {
		return err
	}

	// mv $tmpDir/$(basename $outermostDir) $dir
	return os.Rename(path.Join(tmpDir, outermostDir), dir)
}
