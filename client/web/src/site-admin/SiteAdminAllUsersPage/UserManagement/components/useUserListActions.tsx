import React, { useState, useCallback } from 'react'

import { useMutation } from '@sourcegraph/http-client'
import { Text } from '@sourcegraph/wildcard'

import { CopyableText } from '../../../../components/CopyableText'
import { randomizeUserPassword, setUserIsSiteAdmin } from '../../../backend'
import { DELETE_USERS, DELETE_USERS_FOREVER, FORCE_SIGN_OUT_USERS } from '../queries'

import { UseUserListActionReturnType, SiteUser, getUsernames } from './UsersList'

export function useUserListActions(onEnd: (error?: any) => void): UseUserListActionReturnType {
    const [forceSignOutUsers] = useMutation(FORCE_SIGN_OUT_USERS)
    const [deleteUsers] = useMutation(DELETE_USERS)
    const [deleteUsersForever] = useMutation(DELETE_USERS_FOREVER)

    const [notification, setNotification] = useState<UseUserListActionReturnType['notification']>()

    const handleDismissNotification = useCallback(() => setNotification(undefined), [])

    const onError = useCallback(
        (error: any) => {
            setNotification({
                text: (
                    <Text as="span">
                        Something went wrong :(!
                        <Text as="pre" className="m-1" size="small">
                            {error?.message}
                        </Text>
                    </Text>
                ),
                isError: true,
            })
            console.error(error)
            onEnd(error)
        },
        [onEnd]
    )

    const createOnSuccess = useCallback(
        (text: React.ReactNode, shouldReload = false) => () => {
            setNotification({ text })
            if (shouldReload) {
                onEnd()
            }
        },
        [onEnd]
    )

    const handleForceSignOutUsers = useCallback(
        (users: SiteUser[]) => {
            if (confirm('Are you sure you want to force sign out the selected user(s)?')) {
                forceSignOutUsers({ variables: { userIDs: users.map(user => user.id) } })
                    .then(
                        createOnSuccess(
                            <Text as="span">
                                Successfully force signed out following {users.length} user(s):{' '}
                                <strong>{getUsernames(users)}</strong>
                            </Text>
                        )
                    )
                    .catch(onError)
            }
        },
        [forceSignOutUsers, onError, createOnSuccess]
    )

    const handleDeleteUsers = useCallback(
        (users: SiteUser[]) => {
            if (confirm('Are you sure you want to delete the selected user(s)?')) {
                deleteUsers({ variables: { userIDs: users.map(user => user.id) } })
                    .then(
                        createOnSuccess(
                            <Text as="span">
                                Successfully deleted following {users.length} user(s):{' '}
                                <strong>{getUsernames(users)}</strong>
                            </Text>,
                            true
                        )
                    )
                    .catch(onError)
            }
        },
        [deleteUsers, onError, createOnSuccess]
    )
    const handleDeleteUsersForever = useCallback(
        (users: SiteUser[]) => {
            if (confirm('Are you sure you want to delete the selected user(s)?')) {
                deleteUsersForever({ variables: { userIDs: users.map(user => user.id) } })
                    .then(
                        createOnSuccess(
                            <Text as="span">
                                Successfully deleted forever following {users.length} user(s):{' '}
                                <strong>{getUsernames(users)}</strong>
                            </Text>,
                            true
                        )
                    )
                    .catch(onError)
            }
        },
        [deleteUsersForever, onError, createOnSuccess]
    )

    const handlePromoteToSiteAdmin = useCallback(
        ([user]: SiteUser[]) => {
            if (confirm('Are you sure you want to promote the selected user to site admin?')) {
                setUserIsSiteAdmin(user.id, true)
                    .toPromise()
                    .then(
                        createOnSuccess(
                            <Text as="span">
                                Successfully promoted user <strong>{user.username}</strong> to site admin.
                            </Text>,
                            true
                        )
                    )
                    .catch(onError)
            }
        },
        [onError, createOnSuccess]
    )

    const handleRevokeSiteAdmin = useCallback(
        ([user]: SiteUser[]) => {
            if (confirm('Are you sure you want to revoke the selected user from site admin?')) {
                setUserIsSiteAdmin(user.id, false)
                    .toPromise()
                    .then(
                        createOnSuccess(
                            <Text as="span">
                                Successfully revoked site admin from <strong>{user.username}</strong> user.
                            </Text>,
                            true
                        )
                    )
                    .catch(onError)
            }
        },
        [onError, createOnSuccess]
    )

    const handleResetUserPassword = useCallback(
        ([user]: SiteUser[]) => {
            if (confirm('Are you sure you want to reset the selected user password?')) {
                randomizeUserPassword(user.id)
                    .toPromise()
                    .then(({ resetPasswordURL }) => {
                        if (resetPasswordURL === null) {
                            createOnSuccess(
                                <Text as="span">
                                    Password was reset. The reset link was sent to the primary email of the user:{' '}
                                    <strong>{user.username}</strong>
                                </Text>
                            )()
                        } else {
                            createOnSuccess(
                                <>
                                    <Text>
                                        Password was reset. You must manually send <strong>{user.username}</strong> this
                                        reset link:
                                    </Text>
                                    <CopyableText text={resetPasswordURL} size={40} />
                                </>
                            )()
                        }
                    })
                    .catch(onError)
            }
        },
        [onError, createOnSuccess]
    )

    return {
        notification,
        handleForceSignOutUsers,
        handleDeleteUsers,
        handleDeleteUsersForever,
        handlePromoteToSiteAdmin,
        handleRevokeSiteAdmin,
        handleResetUserPassword,
        handleDismissNotification,
    }
}
