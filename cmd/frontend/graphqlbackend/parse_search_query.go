package graphqlbackend

import (
	"context"

	"github.com/sourcegraph/sourcegraph/internal/search"
	"github.com/sourcegraph/sourcegraph/internal/search/job"
	"github.com/sourcegraph/sourcegraph/internal/search/job/jobutil"
	"github.com/sourcegraph/sourcegraph/internal/search/job/printer"
	"github.com/sourcegraph/sourcegraph/internal/search/query"
	"github.com/sourcegraph/sourcegraph/schema"
)

func (r *schemaResolver) ParseSearchQuery(ctx context.Context, args *struct {
	Query       string
	PatternType string
}) (*JSONValue, error) {
	var searchType query.SearchType
	switch args.PatternType {
	case "literal":
		searchType = query.SearchTypeLiteral
	case "structural":
		searchType = query.SearchTypeStructural
	case "regexp", "regex":
		searchType = query.SearchTypeRegex
	default:
		searchType = query.SearchTypeLiteral
	}

	plan, err := query.Pipeline(query.Init(args.Query, searchType))
	if err != nil {
		return nil, err
	}

	j, err := jobutil.NewPlanJob(&search.Inputs{
		UserSettings: &schema.Settings{},
		PatternType: query.SearchTypeStandard,
		Protocol: search.Streaming,
		Features: &search.Features{},
		OnSourcegraphDotCom: false,
	}, plan)

	mermaid := printer.MermaidVerbose(j, job.VerbosityNone)

/*
	jsonString, err := query.ToJSON(plan.ToQ())
	if err != nil {
		return nil, err
	}
*/
	return &JSONValue{Value: mermaid}, nil
}
