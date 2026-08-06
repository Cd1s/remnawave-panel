#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/.github/scripts/upstream-sync-lib.sh"
WORKFLOW="$ROOT/.github/workflows/upstream-sync.yml"
failures=0
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
file_contains() { grep -Fq -- "$2" "$1"; }

make_repo() {
    fixture_root="$(mktemp -d)"; repo="$fixture_root/repo"; origin="$fixture_root/origin.git"; mkdir -p "$repo"
    git init -q "$repo"; git -C "$repo" config user.name test; git -C "$repo" config user.email test@example.invalid; git -C "$repo" checkout -q -b singbox
    printf 'base\n' >"$repo/state"; git -C "$repo" add state; git -C "$repo" commit -q -m base
    git init -q --bare "$origin"; git -C "$repo" remote add origin "$origin"; git -C "$repo" push -q origin HEAD:singbox
    printf 'fork\n' >>"$repo/state"; git -C "$repo" add state; git -C "$repo" commit -q -m fork; maintained_sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -q -b upstream-main HEAD~1; printf 'upstream\n' >>"$repo/upstream-only"; git -C "$repo" add upstream-only; git -C "$repo" commit -q -m upstream; upstream_sha="$(git -C "$repo" rev-parse HEAD)"; git -C "$repo" checkout -q singbox
    mock_bin="$fixture_root/bin"; mkdir -p "$mock_bin"; real_git="$(command -v git)"
    cat >"$mock_bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = ls-remote ]; then printf '%s\trefs/tags/%s^{}\n' "$FAKE_UPSTREAM_COMMIT" "$FAKE_TAG"; exit 0; fi
if [ "${1:-}" = merge ] && [ "${2:-}" = --abort ] && [ "${FAKE_ABORT:-0}" = 1 ]; then exit 77; fi
exec "$REAL_GIT" "$@"
EOF
    chmod +x "$mock_bin/git"
}

test_resolver() {
    make_repo
    cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = api ]; then printf '%s\n' '[{"tag_name":"3.1.0","html_url":"https://example.invalid/3.1.0","published_at":"2026-07-01T00:00:00Z","draft":false,"prerelease":false},{"tag_name":"3.2.0-rc.1","html_url":"https://example.invalid/rc","published_at":"2026-08-01T00:00:00Z","draft":false,"prerelease":true},{"tag_name":"3.2.0","html_url":"https://example.invalid/3.2.0","published_at":"2026-08-02T00:00:00Z","draft":false,"prerelease":false}]'; exit 0; fi
exit 2
EOF
    chmod +x "$mock_bin/gh"; output="$fixture_root/output"
    (cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" FAKE_UPSTREAM_COMMIT="$upstream_sha" FAKE_TAG=3.2.0 UPSTREAM_REPO=remnawave/test GITHUB_OUTPUT="$output" bash "$LIB" resolve) >/dev/null 2>&1 || return 1
    file_contains "$output" 'tag=3.2.0' && file_contains "$output" 'version=3.2.0' && file_contains "$output" "commit=$upstream_sha"
}

test_empty_and_network_errors_classified() {
    make_repo
    for mode in empty network; do
        if [ "$mode" = empty ]; then printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' >"$mock_bin/gh"; else printf '#!/usr/bin/env bash\necho network >&2\nexit 28\n' >"$mock_bin/gh"; fi
        chmod +x "$mock_bin/gh"; output="$fixture_root/output"
        result="$(cd "$repo"; PATH="$mock_bin:$PATH" GITHUB_OUTPUT="$output" UPSTREAM_REPO=remnawave/test bash "$LIB" resolve 2>&1)" && return 1
        if [ "$mode" = empty ]; then
            contains "$result" 'reason=no_stable_release' || return 1
        else
            contains "$result" 'reason=release_query_error' || return 1
        fi
    done
}
test_historical_tag_collision_fetch_is_safe() {
    fixture_root="$(mktemp -d)"
    repo="$fixture_root/repo"
    upstream_source="$fixture_root/upstream-source"
    upstream="$fixture_root/upstream.git"
    mkdir -p "$repo" "$upstream_source"
    git init -q "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" checkout -q -b singbox
    printf 'fork\n' >"$repo/state"
    git -C "$repo" add state
    git -C "$repo" commit -q -m fork
    fork_tag_sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" tag 3.2.0
    git init -q "$upstream_source"
    git -C "$upstream_source" config user.name upstream
    git -C "$upstream_source" config user.email upstream@example.invalid
    git -C "$upstream_source" checkout -q -b main
    printf 'upstream\n' >"$upstream_source/state"
    git -C "$upstream_source" add state
    git -C "$upstream_source" commit -q -m upstream
    upstream_sha="$(git -C "$upstream_source" rev-parse HEAD)"
    git -C "$upstream_source" tag 3.2.0
    git init -q --bare "$upstream"
    git -C "$upstream_source" remote add origin "$upstream"
    git -C "$upstream_source" push -q origin main refs/tags/3.2.0
    git -C "$repo" remote add upstream "$upstream"

    # RED: this is the previous workflow command and must fail on a fork-owned tag collision.
    git -C "$repo" fetch --no-tags upstream main >/dev/null 2>&1 || return 1
    [ "$(git -C "$repo" rev-parse refs/tags/3.2.0)" = "$fork_tag_sha" ] || return 1
    [ "$(git -C "$repo" rev-parse refs/remotes/upstream/main)" = "$upstream_sha" ] || return 1
    ! file_contains "$WORKFLOW" 'git fetch --force' || return 1
    ! file_contains "$WORKFLOW" 'refs/tags/${{ steps.release.outputs.tag }}:refs/tags/upstream-release-${{ steps.release.outputs.tag }}'
}

test_merge_and_abort_contract() {
    make_repo
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" UPSTREAM_REF="$upstream_sha" UPSTREAM_SYNC_REPORT_PATH="$fixture_root/report" bash "$LIB" merge 2>&1)" || return 1
    contains "$result" 'upstream_sync=merged' || return 1
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" UPSTREAM_REF="$upstream_sha" UPSTREAM_SYNC_REPORT_PATH="$fixture_root/report" bash "$LIB" merge 2>&1)" || return 1
    contains "$result" 'upstream_sync=up_to_date'
}

test_current_release_contract_does_not_require_package_json() {
    make_repo
    git -C "$repo" checkout -q -b upstream-release HEAD~1
    printf 'Backend: v3.2.0\nFrontend: v3.2.0\n' >"$repo/current-release.md"
    git -C "$repo" add current-release.md
    git -C "$repo" commit -q -m upstream-release
    release_sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -q singbox
    printf 'Backend: v3.2.0\nFrontend: v3.2.0\n' >"$repo/current-release.md"
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" UPSTREAM_REF="$release_sha" RELEASE_FILE_PATH=current-release.md bash "$LIB" release-file 2>&1)" || return 1
    contains "$result" 'release_contract=passed'
}

test_workflow_contract() {
    ! file_contains "$WORKFLOW" 'schedule:' || return 1; ! file_contains "$WORKFLOW" '*/5 * * * *' || return 1; [ -z "$(awk '/^jobs:/{exit} /\$\{\{ runner\.temp \}\}/{print NR}' "$WORKFLOW")" ] || return 1; file_contains "$WORKFLOW" 'workflow_dispatch:' || return 1; file_contains "$WORKFLOW" 'cancel-in-progress: false' || return 1; file_contains "$WORKFLOW" 'WORKFLOW_TOKEN' || return 1; file_contains "$WORKFLOW" 'upstream-sync-lib.sh preflight' || return 1; file_contains "$WORKFLOW" 'actions/upload-artifact@v4' || return 1
    preflight_line="$(grep -n -m1 'upstream-sync-lib.sh preflight' "$WORKFLOW" | cut -d: -f1)"; push_line="$(grep -n -m1 'git push origin HEAD:singbox' "$WORKFLOW" | cut -d: -f1)"; [ -n "$preflight_line" ] && [ -n "$push_line" ] && [ "$preflight_line" -lt "$push_line" ] || return 1
    file_contains "$WORKFLOW" 'git push origin HEAD:singbox'
}

test_upstream_main_fetch_does_not_import_tags() {
    file_contains "$WORKFLOW" 'git fetch --no-tags upstream main' &&
        ! file_contains "$WORKFLOW" 'refs/tags/${{ steps.release.outputs.tag }}:refs/tags/upstream-release-${{ steps.release.outputs.tag }}'
}

test_workflow_fetches_resolved_release_before_merge() {
    main_fetch_line="$(grep -n -m1 'git fetch --no-tags upstream main' "$WORKFLOW" | cut -d: -f1)"
    ref_fetch_line="$(grep -n -m1 'git fetch --no-tags upstream "${UPSTREAM_REF}"' "$WORKFLOW" | cut -d: -f1)"
    merge_line="$(grep -n -m1 'upstream-sync-lib.sh merge' "$WORKFLOW" | cut -d: -f1)"
    [ -n "$main_fetch_line" ] && [ -n "$ref_fetch_line" ] && [ "$ref_fetch_line" -lt "$merge_line" ] &&
        ! grep -Eq 'git fetch ([^[:space:]]+ )*--tags([[:space:]]|$)' "$WORKFLOW"
}

test_panel_release_contract_uses_official_tag() {
    ! file_contains "$WORKFLOW" 'bash .github/scripts/upstream-sync-lib.sh package' &&
        file_contains "$WORKFLOW" 'bash .github/scripts/upstream-sync-lib.sh release-file' &&
        file_contains "$WORKFLOW" 'official_panel_release_tag=${{ steps.release.outputs.tag }}'
}

test_checkout_and_readonly_resolver_use_builtin_token() {
    file_contains "$WORKFLOW" 'token: ${{ secrets.GITHUB_TOKEN }}' &&
        ! file_contains "$WORKFLOW" 'token: ${{ secrets.WORKFLOW_TOKEN }}' &&
        file_contains "$WORKFLOW" 'GH_TOKEN: ${{ github.token }}' &&
        ! file_contains "$WORKFLOW" 'GH_TOKEN: ${{ secrets.WORKFLOW_TOKEN || secrets.GITHUB_TOKEN }}' &&
        file_contains "$WORKFLOW" 'GITHUB_TOKEN: ${{ github.token }}' &&
        file_contains "$WORKFLOW" 'workflow_token_query_error' &&
        file_contains "$WORKFLOW" 'WORKFLOW_TOKEN: ${{ secrets.WORKFLOW_TOKEN }}'
}

test_push_uses_ephemeral_workflow_auth() {
    file_contains "$WORKFLOW" 'GIT_CONFIG_KEY_0=http.https://github.com/.extraheader' &&
    file_contains "$WORKFLOW" 'GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth_header"' &&
        ! file_contains "$WORKFLOW" 'GH_TOKEN: ${{ secrets.WORKFLOW_TOKEN || secrets.GITHUB_TOKEN }}' &&
        file_contains "$WORKFLOW" 'WORKFLOW_TOKEN: ${{ secrets.WORKFLOW_TOKEN }}' &&
        file_contains "$WORKFLOW" 'GITHUB_TOKEN: ${{ github.token }}' &&
        file_contains "$WORKFLOW" 'WORKFLOW_CHANGED: ${{ steps.sync.outputs.workflow_changed }}' &&
        file_contains "$WORKFLOW" 'push_token="$GITHUB_TOKEN"' &&
        file_contains "$WORKFLOW" 'push_token="$WORKFLOW_TOKEN"' &&
        ! file_contains "$WORKFLOW" 'PACKAGE_TOKEN' &&
        file_contains "$WORKFLOW" 'git config --unset-all http.https://github.com/.extraheader || true' &&
        ! file_contains "$WORKFLOW" 'Configure ephemeral GitHub auth for push'
}

test_push_auth_never_duplicates_checkout_extraheader() {
    file_contains "$WORKFLOW" 'GITHUB_TOKEN: ${{ github.token }}' || return 1
    file_contains "$WORKFLOW" 'WORKFLOW_CHANGED:' || return 1
    file_contains "$WORKFLOW" 'push_token=' || return 1
    [ "$(grep -Fc 'git config --unset-all http.https://github.com/.extraheader || true' "$WORKFLOW")" -eq 2 ] || return 1
    [ "$(grep -Fc 'GIT_CONFIG_COUNT=1' "$WORKFLOW")" -eq 2 ] || return 1
    awk '/if \[.*push_token.*GITHUB_TOKEN.*\]; then/ { in_auth=1; saw_else=0; next } in_auth && /else/ { saw_else=1; next } in_auth && /git config --unset-all http\.https:\/\/github\.com\/\.extraheader \|\| true/ && !saw_else { exit 1 } in_auth && /GIT_CONFIG_COUNT=1/ && !saw_else { exit 1 } in_auth && /fi/ { if (!saw_else) exit 1; in_auth=0 } END { if (in_auth) exit 1 }' "$WORKFLOW"
}

test_capability_preflight_contract() {
    make_repo
    call_log="$fixture_root/gh.log"
    cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$GH_CALL_LOG"
if [ "${1:-}" = api ]; then
    case "${2:-}" in
        repos/Cd1s/test) printf '{"id":123}\n' ;;
        repos/Cd1s/test/releases?per_page=1) printf '[]\n' ;;
        forbidden/packages*|repos/Cd1s/test/actions/workflows) exit 97 ;;
        *) exit 2 ;;
    esac
    exit 0
fi
exit 2
EOF
    chmod +x "$mock_bin/gh"
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" GH_CALL_LOG="$call_log" GITHUB_REPOSITORY=Cd1s/test GH_TOKEN=github-token GITHUB_RUN_ID=panel bash "$LIB" preflight 2>&1)" || return 1
    contains "$result" 'capability_preflight=passed' || return 1
    grep -Fq 'repos/Cd1s/test' "$call_log" || return 1
    ! grep -Fq 'actions/workflows' "$call_log" && ! grep -Fq 'forbidden/packages' "$call_log"
}

test_capability_preflight_rejects_forbidden_probes() {
    make_repo
    call_log="$fixture_root/gh.log"
    cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$GH_CALL_LOG"
if [ "${1:-}" = api ]; then
    case "${2:-}" in
        repos/Cd1s/test) printf '{"id":123}\n' ;;
        "repos/Cd1s/test/releases?per_page=1") printf '[]\n' ;;
        "repos/Cd1s/test/actions/workflows") exit 97 ;;
        *) exit 2 ;;
    esac
    exit 0
fi
exit 2
EOF
    chmod +x "$mock_bin/gh"
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" GH_CALL_LOG="$call_log" GITHUB_REPOSITORY=Cd1s/test GH_TOKEN=github-token GITHUB_RUN_ID=panel bash "$LIB" preflight 2>&1)" || return 1
    contains "$result" 'capability_preflight=passed' || return 1
    ! grep -Fq 'actions/workflows' "$call_log" && ! grep -Fq 'forbidden/packages' "$call_log"
}

test_workflow_diff_without_token_fails_closed() {
    make_repo
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GITHUB_REPOSITORY=Cd1s/test WORKFLOW_CHANGED=true WORKFLOW_TOKEN= bash "$LIB" preflight 2>&1)" && return 1
    contains "$result" 'reason=missing_WORKFLOW_TOKEN workflow_files_changed'
}

test_workflow_diff_with_invalid_token_fails_closed() {
    make_repo
    cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = api ] || exit 2
[ "${2:-}" = user ] && exit 1
printf '{"id":123}\n'
EOF
    chmod +x "$mock_bin/gh"
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GITHUB_REPOSITORY=Cd1s/test GH_TOKEN=github-token WORKFLOW_CHANGED=true WORKFLOW_TOKEN=bad-token bash "$LIB" preflight 2>&1)" && return 1
    contains "$result" 'reason=workflow_token_query_error'
}

test_capability_preflight_rejects_missing_workflow_token_v2() {
    make_repo
    call_log="$fixture_root/gh.log"
    cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$GH_CALL_LOG"
if [ "${1:-}" = api ]; then
    case "${2:-}" in
        repos/Cd1s/test) [ "${3:-}" = --jq ] && printf '123\n' || printf '{"id":123}\n' ;;
        repos/Cd1s/test/releases?per_page=1) printf '[]\n' ;;
        forbidden/packages*|repos/Cd1s/test/actions/workflows) exit 97 ;;
        *) exit 2 ;;
    esac
    exit 0
fi
exit 2
EOF
    chmod +x "$mock_bin/gh"
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GITHUB_REPOSITORY=Cd1s/test WORKFLOW_TOKEN= bash "$LIB" preflight 2>&1)" && return 1
    contains "$result" 'reason=missing_WORKFLOW_TOKEN requires_contents_workflows_packages_release_write'
}

test_capability_preflight_rejects_actions_bypass_v2() {
    make_repo
    cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = api ]; then
    case "${2:-}" in
        repos/Cd1s/test) printf '{"permissions":{"push":false}}\n' ;;
        *) printf '{}\n' ;;
    esac
    exit 0
fi
exit 2
EOF
    chmod +x "$mock_bin/gh"
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GITHUB_REPOSITORY=Cd1s/test WORKFLOW_TOKEN=present GH_TOKEN=present PACKAGE_TOKEN=present SKIP_GIT_DRY_RUN=true GITHUB_ACTIONS=true bash "$LIB" preflight 2>&1)" && return 1
    contains "$result" 'reason=contents_write_denied'
}

run_case() { if "$1"; then pass "$1"; else fail "$1"; fi; }
run_case test_resolver; run_case test_empty_and_network_errors_classified; run_case test_historical_tag_collision_fetch_is_safe; run_case test_merge_and_abort_contract; run_case test_current_release_contract_does_not_require_package_json; run_case test_workflow_contract
run_case test_upstream_main_fetch_does_not_import_tags
run_case test_workflow_fetches_resolved_release_before_merge
run_case test_panel_release_contract_uses_official_tag
run_case test_checkout_and_readonly_resolver_use_builtin_token
run_case test_push_uses_ephemeral_workflow_auth
run_case test_push_auth_never_duplicates_checkout_extraheader
run_case test_capability_preflight_rejects_forbidden_probes
run_case test_workflow_diff_without_token_fails_closed
run_case test_workflow_diff_with_invalid_token_fails_closed
[ "$failures" -eq 0 ] || exit 1
printf 'all upstream hardening tests passed\n'
