import { escapeRegExp } from 'lodash'
import { Observable } from 'rxjs'
import { map, reduce } from 'rxjs/operators'

import { compute } from '@sourcegraph/shared/src/search/stream'
import { isDefined } from '@sourcegraph/shared/src/util/types'

import { AuthenticatedUser } from '../../auth'

export const computeSuggestedRepositories = ({ email, username }: AuthenticatedUser): Observable<string[]> => compute(`type:diff author:(${email}|${username}) after:"two months ago" count:all content:output(.* -> $repo)`).pipe(
    reduce((accumulator, repos) => {
        for (const repo of repos) {
            if (repo !== '') {
                accumulator.set(repo, (accumulator.get(repo) ?? 0) + 1)
            }
        }
        return accumulator
    }, new Map<string, number>()),
    map(accumulatedRepos => [...accumulatedRepos.keys()]
        .sort((a, b) => accumulatedRepos.get(b)! - accumulatedRepos.get(a)!)
    )
)

export const computeSuggestedFiles = ({ email, username }: AuthenticatedUser): Observable<{ repoName: string, filePath: string, url: string }[]> => compute(`type:diff author:(${email}|${username}) count:100 content:output(^[^\\s]+\\s([^\\n]+) -> $repo,$1)`).pipe(
    reduce((accumulator, repoFiles) => {
        for (const repoFile of repoFiles) {
            if (repoFile !== '') {
                accumulator.set(repoFile, (accumulator.get(repoFile) ?? 0) + 1)
            }
        }
        return accumulator
    }, new Map<string, number>()),
    map(accumulatedRepos => [...accumulatedRepos.keys()]
            .sort((a, b) => accumulatedRepos.get(b)! - accumulatedRepos.get(a)!)
            .map(repoFile => repoFile.split(','))
            .map(([repoName, filePath]) => ({ repoName, filePath, url: `${repoName}/-/blob/${filePath}`})))
)

export const computeCommitTopicSearches = ({email, username}: AuthenticatedUser): Observable<{ description: string; query: string; occurrences: number }[]> => compute(`type:commit author:(${email}|${username}) after:"2 months ago" content:output(^(\\w+(\\s\\w+)?): -> $repo,$1) count:all`).pipe(
    reduce((accumulator, repoTopics) => {
        for (const repoTopic of repoTopics) {
            if (repoTopic !== '') {
                const [repo, topic] = repoTopic.split(',')
                const lowercaseTopic = topic.toLowerCase()
                const key = `${repo}${lowercaseTopic}`
                accumulator.set(key, {repo, topic: lowercaseTopic, occurrences: (accumulator.get(key)?.occurrences ?? 0) + 1})
            }
        }
        return accumulator
    }, new Map<string, { occurrences: number; repo: string; topic: string }>()),
    map(topics => [...topics.keys()]
        .sort((a, b) => topics.get(b)?.occurrences! - topics.get(a)?.occurrences!)
        .map(key => topics.get(key))
        .filter(isDefined)
        .map(({repo, topic, occurrences}) => ({
            description: `Commits about '${topic}' in ${repo}`,
            query: `r:^${escapeRegExp(repo)}$ type:commit patterntype:regexp ^${topic}:`,
            occurrences
        })).slice(0, 1)
    )
)

export const computeDigramContentSearches = ({email, username}: AuthenticatedUser): Observable<{ description: string; query: string; occurrences: number }[]> => compute(`type:diff author:(${email}|${username}) after:"2 months ago" content:output(\\b(\\w+ \\w+): -> $repo,$1) count:all`).pipe(
    reduce((accumulator, repoDigrams) => {
        for (const repoDigram of repoDigrams) {
            if (repoDigram !== '') {
                const [repo, digram] = repoDigram.split(',')
                accumulator.set(repoDigram, {repo, topic: digram, occurrences: (accumulator.get(repoDigram)?.occurrences ?? 0) + 1})
            }
        }
        return accumulator
    }, new Map<string, { occurrences: number; repo: string; topic: string }>()),
    map(topics => [...topics.keys()]
        .sort((a, b) => topics.get(b)?.occurrences! - topics.get(a)?.occurrences!)
        .map(key => topics.get(key))
        .filter(isDefined)
        .map(({repo, topic, occurrences}) => ({
            description: `Literal pattern '${topic}' in ${repo}`,
            query: `r:^${escapeRegExp(repo)}$ patterntype:literal ${topic}`,
            occurrences
        })).slice(0, 1)
    )
)

export const computeFunctionCallSearches = ({email, username}: AuthenticatedUser): Observable<{ description: string; query: string; occurrences: number }[]> => compute(`type:diff author:(${email}|${username}) content:output(\\b([\\w_]{10,})\\( -> $repo,$1) count:all`).pipe(
    reduce((accumulator, possibleFunctionNames) => {
        for (const possibleFunctionName of possibleFunctionNames) {
            if (possibleFunctionName !== '') {
                const [repo, digram] = possibleFunctionName.split(',')
                accumulator.set(possibleFunctionName, {repo, topic: digram, occurrences: (accumulator.get(possibleFunctionName)?.occurrences ?? 0) + 1})
            }
        }
        return accumulator
    }, new Map<string, { occurrences: number; repo: string; topic: string }>()),
    map(topics => [...topics.keys()]
        .sort((a, b) => topics.get(b)?.occurrences! - topics.get(a)?.occurrences!)
        .map(key => topics.get(key))
        .filter(isDefined)
        .map(({repo, topic, occurrences}) => ({
            description: `Structural pattern '${topic}(...)' in ${repo}`,
            query: `r:^${escapeRegExp(repo)}$ patterntype:structural ${topic}(...)`,
            occurrences
        })).slice(0, 1)
    )
)

export const computeRegexPatternSearches = ({email, username}: AuthenticatedUser): Observable<{ description: string; query: string; occurrences: number }[]> => compute(`type:diff author:(${email}|${username}) content:output(\\b(\\w{10,})['"]?\\s+[=\\:]\\s+["']?(\\w{4,}) -> $repo,$1.*$2) count:all`).pipe(
    reduce((accumulator, possibleFunctionNames) => {
        for (const possibleFunctionName of possibleFunctionNames) {
            if (possibleFunctionName !== '') {
                const [repo, digram] = possibleFunctionName.split(',')
                accumulator.set(possibleFunctionName, {repo, topic: digram, occurrences: (accumulator.get(possibleFunctionName)?.occurrences ?? 0) + 1})
            }
        }
        return accumulator
    }, new Map<string, { occurrences: number; repo: string; topic: string }>()),
    map(topics => [...topics.keys()]
        .sort((a, b) => topics.get(b)?.occurrences! - topics.get(a)?.occurrences!)
        .map(key => topics.get(key))
        .filter(isDefined)
        .map(({repo, topic, occurrences}) => ({
            description: `Regex pattern '${topic}' in ${repo}`,
            query: `r:^${escapeRegExp(repo)}$ patterntype:regexp ${topic}`,
            occurrences
        })).slice(0, 1)
    )
)
