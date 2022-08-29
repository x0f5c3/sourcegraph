import { Remote } from 'comlink'
<<<<<<< Updated upstream
import { Observable, Unsubscribable } from 'rxjs'
||||||| constructed merge base
import { from, Observable, Subscription, Unsubscribable } from 'rxjs'
import { switchMap } from 'rxjs/operators'
=======
import * as comlink from 'comlink'

import { from, NEVER, Observable, Subscription, Unsubscribable, of } from 'rxjs'
import { switchMap } from 'rxjs/operators'
import { proxySubscribable } from '../api/extension/api/common'
>>>>>>> Stashed changes

import type { CommandEntry, ExecuteCommandParameters } from '../api/client/mainthread-api'
import type { FlatExtensionHostAPI } from '../api/contract'
import type { PlainNotification } from '../api/extension/extensionHostApi'

export interface Controller extends Unsubscribable {
    /**
     * Executes the command (registered in the CommandRegistry) specified in params. If an error is thrown, the
     * error is returned *and* emitted on the {@link Controller#notifications} observable.
     *
     * All callers should execute commands using this method instead of calling
     * {@link sourcegraph:CommandRegistry#executeCommand} directly (to ensure errors are emitted as notifications).
     *
     * @param suppressNotificationOnError By default, if command execution throws (or rejects with) an error, the
     * error will be shown in the global notification UI component. Pass suppressNotificationOnError as true to
     * skip this. The error is always returned to the caller.
     */
    executeCommand(parameters: ExecuteCommandParameters, suppressNotificationOnError?: boolean): Promise<any>

    registerCommand(entryToRegister: CommandEntry): Unsubscribable

    commandErrors: Observable<PlainNotification>

    /**
     * Frees all resources associated with this client.
     */
    unsubscribe(): void

    extHostAPI: Promise<Remote<FlatExtensionHostAPI>>
}

/**
 * React props or state containing the client. There should be only a single client for the whole
 * application.
 */
export interface ExtensionsControllerProps<K extends keyof Controller = keyof Controller> {
    /**
     * The client, which is used to communicate with and manage extensions.
     */
<<<<<<< Updated upstream
    extensionsController: Pick<Controller, K> | null
||||||| constructed merge base
    extensionsController: Pick<Controller, K>
=======
    extensionsController: Pick<Controller, K> // ##
>>>>>>> Stashed changes
}
export interface RequiredExtensionsControllerProps<K extends keyof Controller = keyof Controller> {
    extensionsController: Pick<Controller, K>
}

export function createNoopController(): Controller {
    return {
        executeCommand: () => Promise.resolve(),
        commandErrors: NEVER,
        registerCommand: () => {
            return {
                unsubscribe: () => {},
            }
        },
        extHostAPI: Promise.resolve(comlink.wrap<FlatExtensionHostAPI>(noopFlatExtensionHostAPI)),
        unsubscribe: () => {},
    }
}

const NOOP = () => {}
const NOOP_EMPTY_ARRAY_PROXY = () => proxySubscribable(of([]))
const NOOP_NEVER_PROXY = () => proxySubscribable(NEVER)

const noopFlatExtensionHostAPI: FlatExtensionHostAPI = {
    syncSettingsData: NOOP,

    addWorkspaceRoot: NOOP,
    getWorkspaceRoots: NOOP_EMPTY_ARRAY_PROXY,
    removeWorkspaceRoot: NOOP,

    setSearchContext: NOOP,
    transformSearchQuery: (query: string) => proxySubscribable(of(query)),

    getHover: () => proxySubscribable(of({ isLoading: true, result: null })),
    getDocumentHighlights: NOOP_EMPTY_ARRAY_PROXY,
    getDefinition: () => proxySubscribable(of({ isLoading: true, result: [] })),
    getReferences: () => proxySubscribable(of({ isLoading: true, result: [] })),
    getLocations: () => proxySubscribable(of({ isLoading: true, result: [] })),

    hasReferenceProvidersForDocument: () => proxySubscribable(of(false)),

    getFileDecorations: () => proxySubscribable(of({})),

    updateContext: NOOP,

    registerContributions: (): any => ({
        unsubscribe: NOOP,
    }),
    getContributions: () => proxySubscribable(of({})),

    addTextDocumentIfNotExists: NOOP,

    getActiveViewComponentChanges: () => proxySubscribable(of(undefined)),

    getActiveCodeEditorPosition: () => proxySubscribable(of(null)),

    getTextDecorations: NOOP_EMPTY_ARRAY_PROXY,

    addViewerIfNotExists: () => ({ viewerId: '' }),
    viewerUpdates: NOOP_NEVER_PROXY,

    setEditorSelections: NOOP,
    removeViewer: NOOP,

    getPlainNotifications: NOOP_NEVER_PROXY,
    getProgressNotifications: NOOP_NEVER_PROXY,

    getPanelViews: NOOP_EMPTY_ARRAY_PROXY,

    getInsightViewById: NOOP_NEVER_PROXY,
    getInsightsViews: NOOP_EMPTY_ARRAY_PROXY,

    getHomepageViews: NOOP_EMPTY_ARRAY_PROXY,

    getDirectoryViews: NOOP_EMPTY_ARRAY_PROXY,

    getGlobalPageViews: NOOP_EMPTY_ARRAY_PROXY,
    getStatusBarItems: NOOP_EMPTY_ARRAY_PROXY,

    getLinkPreviews: () => proxySubscribable(of(null)),

    haveInitialExtensionsLoaded: () => proxySubscribable(of(false)),

    getActiveExtensions: NOOP_EMPTY_ARRAY_PROXY,
}
