package langp

import "sourcegraph.com/sourcegraph/sourcegraph/pkg/lsp"

// Error is returned in the event of any request error, in addition to the HTTP
// status 400 Bad Request.
type Error struct {
	// ErrorMsg, if any, specifies that there was an error serving the request.
	ErrorMsg string `json:"Error"`
}

// Error implements the error interface.
func (e *Error) Error() string {
	return e.ErrorMsg
}

// Position represents a single specific position within a file located in a
// repository at a given revision.
type Position struct {
	// Repo is the repository URI in which the file is located.
	Repo string

	// Commit is the Git commit ID (not branch) of the repository.
	Commit string

	// File is the file which the user is viewing, relative to the repository root.
	File string

	// Line is the line number in the file (zero based), e.g. where a user's cursor
	// is located within the file.
	Line int

	// Character is the character offset on a line in the file (zero based), e.g.
	// where a user's cursor is located within the file.
	Character int
}

// LSP converts this langp position into its closest LSP equivalent.
func (p Position) LSP() *lsp.TextDocumentPositionParams {
	return &lsp.TextDocumentPositionParams{
		TextDocument: lsp.TextDocumentIdentifier{URI: p.File},
		Position: lsp.Position{
			Line:      p.Line,
			Character: p.Character,
		},
	}
}

// Range represents a specific range within a file.
type Range struct {
	// Repo is the repository URI in which the file is located.
	Repo string

	// Commit is the Git commit ID (not branch) of the repository.
	Commit string

	// File is the file which the user is viewing, relative to the repository root.
	File string

	// StartLine is the starting line number in the file (zero based), i.e.
	// where the range starts.
	StartLine int

	// EndLine is the ending line number in the file (zero based), i.e. where
	// the range ends.
	EndLine int

	// StartCharacter is the starting character offset on the starting line in
	// the file (zero based).
	StartCharacter int

	// EndCharacter is the ending character offset on the ending line in the
	// file (zero based).
	EndCharacter int
}

// LSP converts this langp range into its LSP equivalent.
func (r Range) LSP() lsp.Range {
	return lsp.Range{
		Start: lsp.Position{
			Line:      r.StartLine,
			Character: r.StartCharacter,
		},
		End: lsp.Position{
			Line:      r.EndLine,
			Character: r.EndCharacter,
		},
	}
}

// RepoRev represents a repository at a specific commit.
type RepoRev struct {
	// Repo is the repository URI.
	Repo string

	// Commit is the Git commit ID (not branch) of the repository.
	Commit string
}

// DefSpec is a globally unique identifier for a definition in a repository at
// a specific revision.
type DefSpec struct {
	// Repo is the repository URI.
	Repo string

	// Commit is the Git commit ID (not branch) of the repository.
	Commit string

	// UnitType (example GoPackage)
	UnitType string

	// Unit (example net/http)
	Unit string

	// Path (example NewRequest)
	Path string
}

// LocalRefs represents references to a specific definition.
type LocalRefs struct {
	// Refs is a list of references to a definition defined within the requested
	// repository.
	Refs []Range
}

// ExternalRefs contains a list of all Defs used in a repository, but defined
// outside of it.
type ExternalRefs struct {
	Defs []DefSpec
}

// ExportedSymbols contains a list of all Defs available for use by other
// repositories.
type ExportedSymbols struct {
	Defs []DefSpec
}

// HoverContent represents a subset of the content for when a user “hovers”
// over a definition.
//
// For example, one HoverContent object may represent the comments of a
// function, while the another HoverContent object may represent the function
// signature. In the future we may abuse this field to carry more data, and
// thus we use “type” instead of “language” like in LSP. In practice at this
// point, it always maps to a language (Go, Java, etc).
type HoverContent struct {
	// Type is the type of content (e.g. "Go").
	Type string

	// Value is the value of the content (e.g. "func NewRequest() *Request").
	Value string
}

// Hover represents a message for when a user "hovers" over a definition. It is
// a human-readable description of a definition.
type Hover struct {
	Contents []HoverContent
}

func HoverFromLSP(l lsp.Hover) *Hover {
	h := &Hover{
		Contents: make([]HoverContent, len(l.Contents)),
	}
	for i, marked := range l.Contents {
		h.Contents[i] = HoverContent{
			Type:  marked.Language,
			Value: marked.Value,
		}
	}
	return h
}

// File is returned by ResolveFile to convert workspace paths into objects
// Sourcegraph understands.
type File struct {
	// Repo is the repository URI in which the file is located.
	Repo string

	// Commit is the Git commit ID (not branch) of the repository.
	Commit string

	// Path is the file which the user is viewing, relative to the repository root.
	Path string
}
