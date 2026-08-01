#!/usr/bin/env bash
set -euo pipefail

resolve_latest_release() {
    : "${UPSTREAM_REPO:?UPSTREAM_REPO is required}"
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

    release_json="$(gh release view --repo "$UPSTREAM_REPO" --json tagName,url,publishedAt,isDraft,isPrerelease)"
    release_tag="$(jq -r '.tagName' <<<"$release_json")"
    release_url="$(jq -r '.url' <<<"$release_json")"
    release_published_at="$(jq -r '.publishedAt' <<<"$release_json")"
    release_version="${release_tag#v}"
    if [ "$(jq -r '.isDraft' <<<"$release_json")" != 'false' ] || [ "$(jq -r '.isPrerelease' <<<"$release_json")" != 'false' ]; then
        echo "release_sync=failed reason=latest_release_is_not_stable repo=${UPSTREAM_REPO}" >&2
        exit 1
    fi
    if [ -z "$release_tag" ] || [ "$release_tag" = 'null' ] || [ -z "$release_version" ]; then
        echo "release_sync=failed reason=latest_release_tag_missing repo=${UPSTREAM_REPO}" >&2
        exit 1
    fi
    {
        echo "tag=${release_tag}"
        echo "version=${release_version}"
        echo "url=${release_url}"
        echo "published_at=${release_published_at}"
    } >>"$GITHUB_OUTPUT"
    echo "official_release repo=${UPSTREAM_REPO} tag=${release_tag} version=${release_version} url=${release_url}"
}

sync_release() {
    : "${FORK_REPO:?FORK_REPO is required}"
    : "${FORK_COMMIT:?FORK_COMMIT is required}"
    : "${UPSTREAM_REPO:?UPSTREAM_REPO is required}"
    : "${UPSTREAM_RELEASE_TAG:?UPSTREAM_RELEASE_TAG is required}"
    : "${UPSTREAM_RELEASE_URL:?UPSTREAM_RELEASE_URL is required}"
    : "${UPSTREAM_RELEASE_VERSION:?UPSTREAM_RELEASE_VERSION is required}"
    : "${CI_RUN_URL:?CI_RUN_URL is required}"

    if ! git rev-parse --verify "${FORK_COMMIT}^{commit}" >/dev/null 2>&1; then
        echo "release_sync=failed reason=final_commit_not_found commit=${FORK_COMMIT}" >&2
        exit 1
    fi
    set +e
    remote_head="$(git ls-remote origin refs/heads/singbox 2>&1)"
    remote_rc=$?
    set -e
    if [ "$remote_rc" -ne 0 ]; then
        echo "$remote_head" >&2
        echo "release_sync=failed reason=remote_branch_query_error" >&2
        exit "$remote_rc"
    fi
    remote_head="$(awk 'NR == 1 { print $1 }' <<<"$remote_head")"
    if [ "$remote_head" != "$FORK_COMMIT" ]; then
        echo "release_sync=failed reason=remote_branch_not_at_final_commit expected=${FORK_COMMIT} actual=${remote_head:-missing}" >&2
        exit 1
    fi

    set +e
    tag_refs="$(git ls-remote origin "refs/tags/${UPSTREAM_RELEASE_TAG}" "refs/tags/${UPSTREAM_RELEASE_TAG}^{}" 2>&1)"
    tag_rc=$?
    set -e
    if [ "$tag_rc" -ne 0 ]; then
        echo "$tag_refs" >&2
        echo "release_sync=failed reason=remote_tag_query_error tag=${UPSTREAM_RELEASE_TAG}" >&2
        exit "$tag_rc"
    fi
    tag_commit=''
    while IFS=$'\t' read -r sha ref; do
        case "$ref" in
            "refs/tags/${UPSTREAM_RELEASE_TAG}^{}") tag_commit="$sha" ;;
            "refs/tags/${UPSTREAM_RELEASE_TAG}")
                if [ -z "$tag_commit" ]; then tag_commit="$sha"; fi
                ;;
        esac
    done <<<"$tag_refs"

    set +e
    release_output="$(gh release view "$UPSTREAM_RELEASE_TAG" --repo "$FORK_REPO" --json tagName,url 2>&1)"
    release_rc=$?
    set -e
    release_exists=false
    if [ "$release_rc" -eq 0 ]; then
        release_exists=true
        existing_release_tag="$(jq -r '.tagName' <<<"$release_output")"
        if [ "$existing_release_tag" != "$UPSTREAM_RELEASE_TAG" ]; then
            echo "release_sync=failed reason=release_tag_mismatch expected=${UPSTREAM_RELEASE_TAG} actual=${existing_release_tag:-missing}" >&2
            exit 1
        fi
    else
        release_error_lower="$(tr '[:upper:]' '[:lower:]' <<<"$release_output")"
        if [[ "$release_error_lower" != *'release not found'* && "$release_error_lower" != *'http 404'* ]]; then
            echo "$release_output" >&2
            echo "release_sync=failed reason=release_query_error tag=${UPSTREAM_RELEASE_TAG}" >&2
            exit "$release_rc"
        fi
    fi

    if [ "$release_exists" = true ] && [ -z "$tag_commit" ]; then
        echo "release_sync=failed reason=release_exists_but_tag_missing tag=${UPSTREAM_RELEASE_TAG}" >&2
        exit 1
    fi
    if [ "$release_exists" = true ]; then
        echo "release_sync=skipped tag=${UPSTREAM_RELEASE_TAG} commit=${FORK_COMMIT} reason=release_and_tag_already_exist"
        exit 0
    fi

    if [ -n "$tag_commit" ] && [ "$tag_commit" != "$FORK_COMMIT" ]; then
        echo "release_sync=failed reason=tag_exists_without_release_points_to_different_commit tag=${UPSTREAM_RELEASE_TAG} expected=${FORK_COMMIT} actual=${tag_commit}" >&2
        exit 1
    fi

    notes="Official Remnawave ${UPSTREAM_RELEASE_VERSION} release for the Sing-box/AnyTLS fork.

Upstream repository: ${UPSTREAM_REPO}
Upstream release tag: ${UPSTREAM_RELEASE_TAG}
Upstream release URL: ${UPSTREAM_RELEASE_URL}
Fork repository: ${FORK_REPO}
Fork branch: singbox
Fork commit: ${FORK_COMMIT}
CI run: ${CI_RUN_URL}

This is a fork release with the official version/tag and the maintained Sing-box/AnyTLS adaptations."
    gh release create "$UPSTREAM_RELEASE_TAG" --repo "$FORK_REPO" --target "$FORK_COMMIT" --title "v${UPSTREAM_RELEASE_VERSION}" --notes "$notes"
    echo "release_sync=created tag=${UPSTREAM_RELEASE_TAG} commit=${FORK_COMMIT}"
}

case "${1:-}" in
    resolve) resolve_latest_release ;;
    sync) sync_release ;;
    *) echo "usage: $0 {resolve|sync}" >&2; exit 2 ;;
esac
