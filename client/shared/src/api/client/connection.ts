import { TextDocumentPositionParameters } from '@sourcegraph/client-api'
import { MaybeLoadingResult } from '@sourcegraph/codeintellify'
import * as comlink from 'comlink'
import { from, Observable, of, Subscription } from 'rxjs'
import { first, map } from 'rxjs/operators'
import { Unsubscribable } from 'sourcegraph'
import { newCodeIntelAPI } from '../../codeintel/api'
import { CodeIntelContext } from '../../codeintel/legacy-extensions/api'

import { PlatformContext, ClosableEndpointPair } from '../../platform/context'
import { isSettingsValid } from '../../settings/settings'
import { FlatExtensionHostAPI, MainThreadAPI } from '../contract'
import { ExtensionHostAPIFactory } from '../extension/api/api'
import { proxySubscribable } from '../extension/api/common'
import { InitData } from '../extension/extensionHost'
import { registerComlinkTransferHandlers } from '../util'

import { ClientAPI } from './api/api'
import { ExposedToClient, initMainThreadAPI } from './mainthread-api'

export interface ExtensionHostClientConnection {
    /**
     * Closes the connection to and terminates the extension host.
     */
    unsubscribe(): void
}

/**
 * An activated extension.
 */
export interface ActivatedExtension {
    /**
     * The extension's extension ID (which uniquely identifies it among all activated extensions).
     */
    id: string

    /**
     * Deactivate the extension (by calling its "deactivate" function, if any).
     */
    deactivate(): void | Promise<void>
}

/**
 * @paramendpoints The Worker object to communicate with
 */
export async function createExtensionHostClientConnection(
    endpointsPromise: Promise<ClosableEndpointPair>,
    initData: Omit<InitData, 'initialSettings'>,
    platformContext: Pick<
        PlatformContext,
        | 'settings'
        | 'updateSettings'
        | 'getGraphQLClient'
        | 'requestGraphQL'
        | 'telemetryService'
        | 'sideloadedExtensionURL'
        | 'getScriptURLForExtension'
        | 'clientApplication'
    >
): Promise<{
    subscription: Unsubscribable
    api: comlink.Remote<FlatExtensionHostAPI>
    mainThreadAPI: MainThreadAPI
    exposedToClient: ExposedToClient
}> {
    const subscription = new Subscription()

    // MAIN THREAD

    registerComlinkTransferHandlers()

    const { endpoints, subscription: endpointsSubscription } = await endpointsPromise
    subscription.add(endpointsSubscription)

    /** Proxy to the exposed extension host API */
    const initializeExtensionHost = comlink.wrap<ExtensionHostAPIFactory>(endpoints.proxy)

    const initialSettings = await from(platformContext.settings).pipe(first()).toPromise()
    const proxy = await initializeExtensionHost({
        ...initData,
        // TODO what to do in error case?
        initialSettings: isSettingsValid(initialSettings) ? initialSettings : { final: {}, subjects: [] },
    })

    const { api: newAPI, exposedToClient, subscription: apiSubscriptions } = initMainThreadAPI(proxy, platformContext)

    subscription.add(apiSubscriptions)

    const clientAPI: ClientAPI = {
        ping: () => 'pong',
        ...newAPI,
    }

    comlink.expose(clientAPI, endpoints.expose)
    proxy.mainThreadAPIInitialized().catch(() => {
        console.error('Error notifying extension host of main thread API init.')
    })

    // TODO(tj): return MainThreadAPI and add to Controller interface
    // to allow app to interact with APIs whose state lives in the main thread
    return {
        subscription,
        // api: proxy, the old code
        api: injectNewCodeintel(proxy, {
            requestGraphQL: platformContext.requestGraphQL,
            telemetryService: platformContext.telemetryService,
            settings: platformContext.settings,
            // TODO searchContext: ???
        }),
        mainThreadAPI: newAPI,
        exposedToClient,
    }
}

// Replaces codeintel functions from the "old" extension/webworker extension API
// with new implementations of code that lives in this repository. The old
// implementation invoked codeintel functions via webworkers, and the codeintel
// implementation lived in a separate repository
// https://github.com/sourcegraph/code-intel-extensions Ideally, we should
// update all the usages of `comlink.Remote<FlatExtensionHostAPI>` with the new
// `CodeIntelAPI` interfaces, but that would require refactoring a lot of files.
// To minimize the risk of breaking changes caused by the deprecation of
// extensions, we monkey patch the old implementation with new implementations.
// The benefit of monkey patching is that we can optionally disable if for
// customers that choose to enable the legacy extensions.
function injectNewCodeintel(
    old: comlink.Remote<FlatExtensionHostAPI>,
    context: CodeIntelContext
): comlink.Remote<FlatExtensionHostAPI> {
    const codeintel = newCodeIntelAPI(context)
    function thenMaybeLoadingResult<T>(promise: Observable<T>): Observable<MaybeLoadingResult<T>> {
        return promise.pipe(
            map(result => {
                const maybeLoadingResult: MaybeLoadingResult<T> = { isLoading: false, result }
                return maybeLoadingResult
            })
        )
    }

    const codeintelOverrides: Pick<
        FlatExtensionHostAPI,
        | 'getHover'
        | 'getDocumentHighlights'
        | 'getReferences'
        | 'getDefinition'
        | 'getLocations'
        | 'hasReferenceProvidersForDocument'
    > = {
        hasReferenceProvidersForDocument(textParameters) {
            return proxySubscribable(codeintel.hasReferenceProvidersForDocument(textParameters))
        },
        getLocations(id, parameters) {
            console.log({ id })
            return proxySubscribable(thenMaybeLoadingResult(codeintel.getImplementations(parameters)))
        },
        getDefinition(parameters) {
            return proxySubscribable(thenMaybeLoadingResult(codeintel.getDefinition(parameters)))
        },
        getReferences(parameters, context) {
            console.log({ parameters })
            return proxySubscribable(thenMaybeLoadingResult(codeintel.getReferences(parameters, context)))
        },
        getDocumentHighlights: (textParameters: TextDocumentPositionParameters) => {
            return proxySubscribable(codeintel.getDocumentHighlights(textParameters))
        },
        getHover: (textParameters: TextDocumentPositionParameters) => {
            return proxySubscribable(thenMaybeLoadingResult(codeintel.getHover(textParameters)))
        },
    }

    return new Proxy(old, {
        get(target, prop) {
            const codeintelFunction = (codeintelOverrides as any)[prop]
            if (codeintelFunction) {
                return codeintelFunction
            }
            return Reflect.get(target, prop, ...arguments)
        },
    })
}
