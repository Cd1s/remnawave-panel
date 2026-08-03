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

test_merge_and_abort_contract() {
    make_repo
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" UPSTREAM_REF="$upstream_sha" UPSTREAM_SYNC_REPORT_PATH="$fixture_root/report" bash "$LIB" merge 2>&1)" || return 1
    contains "$result" 'upstream_sync=merged' || return 1
    result="$(cd "$repo"; PATH="$mock_bin:$PATH" GIT_BIN="$mock_bin/git" REAL_GIT="$real_git" UPSTREAM_REF="$upstream_sha" UPSTREAM_SYNC_REPORT_PATH="$fixture_root/report" bash "$LIB" merge 2>&1)" || return 1
    contains "$result" 'upstream_sync=up_to_date'
}

test_workflow_contract() {
    file_contains "$WORKFLOW" '*/5 * * * *' || return 1; [ -z "$(awk '/^jobs:/{exit} /\$\{\{ runner\.temp \}\}/{print NR}' "$WORKFLOW")" ] || return 1; file_contains "$WORKFLOW" 'workflow_dispatch:' || return 1; file_contains "$WORKFLOW" 'cancel-in-progress: false' || return 1; file_contains "$WORKFLOW" 'WORKFLOW_TOKEN' || return 1; file_contains "$WORKFLOW" 'upstream-sync-lib.sh preflight' || return 1; file_contains "$WORKFLOW" 'upstream-sync-lib.sh package' || return 1; file_contains "$WORKFLOW" 'actions/upload-artifact@v4' || return 1
    preflight_line="$(grep -n -m1 'upstream-sync-lib.sh preflight' "$WORKFLOW" | cut -d: -f1)"; push_line="$(grep -n -m1 'git push origin HEAD:singbox' "$WORKFLOW" | cut -d: -f1)"; [ -n "$preflight_line" ] && [ -n "$push_line" ] && [ "$preflight_line" -lt "$push_line" ] || return 1
    file_contains "$WORKFLOW" 'git push origin HEAD:singbox'
}

test_upstream_tag_fetch_is_namespaced() {
    file_contains "$WORKFLOW" 'refs/tags/${{ steps.release.outputs.tag }}:refs/tags/upstream-release-${{ steps.release.outputs.tag }}'
}

run_case() { if "$1"; then pass "$1"; else fail "$1"; fi; }
run_case test_resolver; run_case test_empty_and_network_errors_classified; run_case test_merge_and_abort_contract; run_case test_workflow_contract
run_case test_upstream_tag_fetch_is_namespaced
[ "$failures" -eq 0 ] || exit 1
printf 'all upstream hardening tests passed\n'
