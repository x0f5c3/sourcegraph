package upload

import (
	"io"
	"os"
	"strconv"
	"sync"

	gzip "github.com/klauspost/pgzip"

	"github.com/sourcegraph/sourcegraph/lib/errors"
	"github.com/sourcegraph/sourcegraph/lib/output"
)

// compressToParts compresses and writes the content of the given reader to temporary
// files of at most maxLen size in bytes and returns the file's path. If the given progress
// object is non-nil, then the progress's first bar will be updated with the percentage of
// bytes read on each read.
func compressToParts(r io.Reader, readerLen, maxLen int64, progress output.Progress) (filenames []string, err error) {
	if progress != nil {
		r = newProgressCallbackReader(r, readerLen, progress, 0)
	}

	// leave 1KB space
	maxLen = maxLen - 1024

	var wg sync.WaitGroup
	wg.Add(1)
	defer wg.Wait()

	readPipe, writePipe := io.Pipe()
	defer readPipe.Close()

	go func() {
		defer wg.Done()
		gzipWriter, _ := gzip.NewWriterLevel(writePipe, gzip.BestCompression)
		if _, copyErr := io.Copy(gzipWriter, r); copyErr != nil && copyErr != io.ErrClosedPipe {
			writePipe.CloseWithError(copyErr)
			err = errors.Append(err, copyErr)
		}
	}()

	index := 0
	for {
		compressedFile, err := os.CreateTemp("", "*-"+strconv.Itoa(index))
		if err != nil {
			return nil, err
		}
		defer func() {
			if closeErr := compressedFile.Close(); err != nil {
				err = errors.Append(err, closeErr)
			}
		}()

		limitReader := io.LimitReader(readPipe, maxLen)
		n, err := io.Copy(compressedFile, limitReader)
		if err != nil {
			return nil, err
		}
		// triggered when write side has completed
		if n == 0 {
			return filenames, nil
		}

		filenames = append(filenames, compressedFile.Name())
	}
}
