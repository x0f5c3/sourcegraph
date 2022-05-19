import classNames from 'classnames'
import FileCodeIcon from 'mdi-react/FileCodeIcon'
import React, { useCallback, useEffect, useMemo, useState } from 'react'
import { Observable, of } from 'rxjs'

import { Link } from '@sourcegraph/shared/src/components/Link'
import { TelemetryProps } from '@sourcegraph/shared/src/telemetry/telemetryService'
import { useObservable } from '@sourcegraph/shared/src/util/useObservable'

import { AuthenticatedUser } from '../../auth'
import { EventLogResult } from '../backend'

import { ActionButtonGroup } from './ActionButtonGroup'
import { EmptyPanelContainer } from './EmptyPanelContainer'
import { LoadingPanelView } from './LoadingPanelView'
import { PanelContainer } from './PanelContainer'
import { ShowMoreButton } from './ShowMoreButton'
import { computeSuggestedFiles } from './suggestedContent'

interface Props extends TelemetryProps {
    className?: string
    authenticatedUser: AuthenticatedUser | null
    fetchRecentFileViews: (userId: string, first: number) => Observable<EventLogResult | null>
}

export const RecentFilesPanel: React.FunctionComponent<Props> = ({
    className,
    authenticatedUser,
    fetchRecentFileViews,
    telemetryService,
}) => {
    const pageSize = 20

    const [filesToShow, setFilesToShow] = useState<'suggested' | 'visited'>('visited')

    const [itemsToLoad, setItemsToLoad] = useState(pageSize)
    const recentFiles = useObservable(
        useMemo(() => fetchRecentFileViews(authenticatedUser?.id || '', itemsToLoad), [
            authenticatedUser?.id,
            fetchRecentFileViews,
            itemsToLoad,
        ])
    )

    const computeRecentFiles = useObservable(useMemo(() =>
        (authenticatedUser ? computeSuggestedFiles(authenticatedUser) : of(undefined))
    , [authenticatedUser]))

    const [processedResults, setProcessedResults] = useState<RecentFile[] | null>(null)

    // Only update processed results when results are valid to prevent
    // flashing loading screen when "Show more" button is clicked
    useEffect(() => {
        if (recentFiles) {
            setProcessedResults(processRecentFiles(recentFiles))
        }
    }, [recentFiles])

    useEffect(() => {
        // Only log the first load (when items to load is equal to the page size)
        if (processedResults && itemsToLoad === pageSize) {
            telemetryService.log(
                'RecentFilesPanelLoaded',
                { empty: processedResults.length === 0 },
                { empty: processedResults.length === 0 }
            )
        }
    }, [processedResults, telemetryService, itemsToLoad])

    const logFileClicked = useCallback(() => telemetryService.log('RecentFilesPanelFileClicked'), [telemetryService])

    const loadingDisplay = <LoadingPanelView text="Loading recent files" />

    const emptyDisplay = (
        <EmptyPanelContainer className="align-items-center text-muted">
            <FileCodeIcon className="mb-2" size="2rem" />
            <small className="mb-2">This panel will display your most recently viewed files.</small>
        </EmptyPanelContainer>
    )

    function loadMoreItems(): void {
        setItemsToLoad(current => current + pageSize)
        telemetryService.log('RecentFilesPanelShowMoreClicked')
    }

    const contentDisplay = filesToShow === 'visited' ? processedResults && processedResults.length > 0 ? (
        <div>
            <dl className="list-group-flush">
                {processedResults.map((recentFile, index) => (
                    <dd key={index} className="text-monospace test-recent-files-item">
                        <small>
                            <Link to={recentFile.url} onClick={logFileClicked} data-testid="recent-files-item">
                                {recentFile.repoName} › {recentFile.filePath}
                            </Link>
                        </small>
                    </dd>
                ))}
            </dl>
            {recentFiles?.pageInfo.hasNextPage && (
                <div>
                    <ShowMoreButton onClick={loadMoreItems} dataTestid="recent-files-panel-show-more" />
                </div>
            )}
        </div>
    ) : emptyDisplay : computeRecentFiles && computeRecentFiles.length > 0 ? (
        <div>
            <dl className="list-group-flush">
                {computeRecentFiles.map((recentFile, index) => (
                    <dd key={index} className="text-monospace test-recent-files-item">
                        <small>
                            <Link to={recentFile.url} onClick={logFileClicked}>
                                {recentFile.repoName} › {recentFile.filePath}
                            </Link>
                        </small>
                    </dd>
                ))}
            </dl>
        </div>
    ) : emptyDisplay

    const actionButtons = computeRecentFiles && computeRecentFiles.length > 0 ? (
        <ActionButtonGroup>
            <div className="btn-group btn-group-sm">
                <button
                    type="button"
                    onClick={() => setFilesToShow('visited')}
                    className={classNames('btn btn-outline-secondary test-saved-search-panel-my-searches', {
                        active: filesToShow === 'visited',
                    })}
                >
                    Recent
                </button>
                <button
                    type="button"
                    onClick={() => setFilesToShow('suggested')}
                    className={classNames('btn btn-outline-secondary test-saved-search-panel-all-searches', {
                        active: filesToShow === 'suggested',
                    })}
                >
                    Suggested
                </button>
            </div>
        </ActionButtonGroup>
    ) : undefined

    return (
        <PanelContainer
            className={classNames(className, 'recent-files-panel')}
            title="Files"
            state={processedResults ? 'populated' : 'loading'}
            loadingContent={loadingDisplay}
            populatedContent={contentDisplay}
            actionButtons={actionButtons}
        />
    )
}

interface RecentFile {
    repoName: string
    filePath: string
    timestamp: string
    url: string
}

function processRecentFiles(eventLogResult?: EventLogResult): RecentFile[] | null {
    if (!eventLogResult) {
        return null
    }

    const recentFiles: RecentFile[] = []

    for (const node of eventLogResult.nodes) {
        if (node.argument && node.url) {
            const parsedArguments = JSON.parse(node.argument)
            let repoName = parsedArguments?.repoName as string
            let filePath = parsedArguments?.filePath as string

            if (!repoName || !filePath) {
                ;({ repoName, filePath } = extractFileInfoFromUrl(node.url))
            }

            if (
                filePath &&
                repoName &&
                !recentFiles.some(file => file.repoName === repoName && file.filePath === filePath) // Don't show the same file twice
            ) {
                const parsedUrl = new URL(node.url)
                recentFiles.push({
                    url: parsedUrl.pathname + parsedUrl.search, // Strip domain from URL so clicking on it doesn't reload page
                    repoName,
                    filePath,
                    timestamp: node.timestamp,
                })
            }
        }
    }

    return recentFiles
}

function extractFileInfoFromUrl(url: string): { repoName: string; filePath: string } {
    const parsedUrl = new URL(url)

    // Remove first character as it's a '/'
    const [repoName, filePath] = parsedUrl.pathname.slice(1).split('/-/blob/')
    if (!repoName || !filePath) {
        return { repoName: '', filePath: '' }
    }

    return { repoName, filePath }
}
