import React, { useCallback, useState } from 'react'

import { SearchPatternType, QueryState } from '@sourcegraph/search'
import { SearchBox } from '@sourcegraph/search-ui'
import { aggregateStreamingSearch, LATEST_VERSION } from '@sourcegraph/shared/src/search/stream'
import { EMPTY_SETTINGS_CASCADE } from '@sourcegraph/shared/src/settings/settings'
import { NOOP_TELEMETRY_SERVICE } from '@sourcegraph/shared/src/telemetry/telemetryService'

import { EMPTY, NEVER, of } from 'rxjs'

import { WildcardThemeContext } from '@sourcegraph/wildcard'

import styles from '../../../vscode/src/webview/search-panel/index.module.scss'

export const App = () => {
    // Toggling case sensitivity or pattern type does NOT trigger a new search on home view.
    const [caseSensitive, setCaseSensitivity] = useState(false)
    const [patternType, setPatternType] = useState(SearchPatternType.literal)
    const [results, setResults] = useState<any[]>([])

    const [userQueryState, setUserQueryState] = useState<QueryState>({
        query: '',
    })

    const onSubmit = useCallback(() => {
        aggregateStreamingSearch(of(userQueryState.query), {
            version: LATEST_VERSION,
            patternType,
            caseSensitive,
            trace: undefined,
            sourcegraphURL: 'https://sourcegraph.com/.api',
            decorationContextLines: 0,
        }).subscribe(searchResults => {
            setResults(searchResults.results)
            console.log(searchResults)
        })

        console.log('onSubmit')
    }, [caseSensitive, patternType, userQueryState])

    const setSelectedSearchContextSpec = useCallback((spec: string) => {
        console.log('setSelectedSearchContextSpec')
    }, [])

    return (
        <WildcardThemeContext.Provider value={{ isBranded: true }}>
            <div className={styles.homeSearchBoxContainer}>
                {/* eslint-disable-next-line react/forbid-elements */}
                <form
                    className="d-flex my-2"
                    onSubmit={event => {
                        event.preventDefault()
                        onSubmit()
                    }}
                >
                    <SearchBox
                        caseSensitive={caseSensitive}
                        setCaseSensitivity={setCaseSensitivity}
                        patternType={patternType}
                        setPatternType={setPatternType}
                        isSourcegraphDotCom={true}
                        hasUserAddedExternalServices={false}
                        hasUserAddedRepositories={true}
                        structuralSearchDisabled={false}
                        queryState={userQueryState}
                        onChange={setUserQueryState}
                        onSubmit={onSubmit}
                        authenticatedUser={null}
                        searchContextsEnabled={true}
                        showSearchContext={true}
                        showSearchContextManagement={false}
                        defaultSearchContextSpec="global"
                        setSelectedSearchContextSpec={setSelectedSearchContextSpec}
                        selectedSearchContextSpec={undefined}
                        fetchSearchContexts={() => {
                            throw new Error('fetchSearchContexts')
                        }}
                        fetchAutoDefinedSearchContexts={() => NEVER}
                        getUserSearchContextNamespaces={() =>
                            // throw new Error('getUserSearchContextNamespaces')
                            []
                        }
                        fetchStreamSuggestions={() =>
                            // throw new Error('fetchStreamSuggestions')
                            NEVER
                        }
                        settingsCascade={EMPTY_SETTINGS_CASCADE}
                        globbing={false}
                        isLightTheme={false}
                        telemetryService={NOOP_TELEMETRY_SERVICE}
                        platformContext={{
                            requestGraphQL: () => EMPTY,
                        }}
                        className=""
                        containerClassName=""
                        autoFocus={true}
                        editorComponent="monaco"
                    />
                </form>
            </div>
            <div>
                <ul>
                    {results.map((r: any) =>
                        r.lineMatches.map((l: any) => (
                            <li>
                                {l.line} <small>{r.path}</small>
                            </li>
                        ))
                    )}
                </ul>
            </div>
        </WildcardThemeContext.Provider>
    )
}
