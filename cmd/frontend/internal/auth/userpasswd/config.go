package userpasswd

import (
	"net/http"

	"github.com/sourcegraph/log"
	"github.com/sourcegraph/sourcegraph/internal/conf"
	"github.com/sourcegraph/sourcegraph/internal/conf/conftypes"
	"github.com/sourcegraph/sourcegraph/schema"
)

// ResetPasswordEnabled reports whether the reset-password flow is enabled (per site config).
func ResetPasswordEnabled() bool {
	pc, multiple := getProviderConfig()
	return pc != nil && !multiple
}

// getProviderConfig returns the builtin auth provider config. At most 1 can be specified in
// site config; if there is more than 1, it returns multiple == true (which the caller should handle
// by returning an error and refusing to proceed with auth).
func getProviderConfig() (pc *schema.BuiltinAuthProvider, multiple bool) {
	for _, p := range conf.Get().AuthProviders {
		if p.Builtin != nil {
			if pc != nil {
				return pc, true // multiple builtin auth providers
			}
			pc = p.Builtin
		}
	}
	return pc, false
}

func handleEnabledCheck(logger log.Logger, w http.ResponseWriter) (handled bool) {
	pc, multiple := getProviderConfig()
	if multiple {
		logger.Error("At most 1 builtin auth provider may be set in site config.")
		http.Error(w, "Misconfigured builtin auth provider.", http.StatusInternalServerError)
		return true
	}
	if pc == nil {
		http.Error(w, "Builtin auth provider is not enabled.", http.StatusForbidden)
		return true
	}
	return false
}

func init() {
	conf.ContributeValidator(validateConfig)
}

func validateConfig(c conftypes.SiteConfigQuerier) (problems conf.Problems) {
	var builtinAuthProviders int
	for _, p := range c.SiteConfig().AuthProviders {
		if p.Builtin != nil {
			builtinAuthProviders++
		}
	}
	if builtinAuthProviders >= 2 {
		problems = append(problems, conf.NewSiteProblem(`at most 1 builtin auth provider may be used`))
	}
	return problems
}
