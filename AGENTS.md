# AI maintainer guide

## Repository role

This is the public panel and documentation fork for the Remnawave Xray + sing-box project.

- Fork: `Cd1s/remnawave-panel`
- Maintained branch: `singbox`
- Upstream: `remnawave/panel` branch `main`
- Runtime backend: `Cd1s/remnawave-backend`
- Runtime frontend: `Cd1s/remnawave-frontend`
- Runtime Node: `Cd1s/remnawave-node`
- Engineering handbook: `Cd1s/remnawave-singbox`

The official `panel` repository is primarily the project website, documentation, and unified
release entry. Product runtime code remains in backend, frontend, and Node repositories. Keep this
fork aligned with that separation.

## Fork-specific responsibilities

This branch should:

- retain the official documentation structure so upstream changes remain mergeable;
- clearly identify the fork as an unofficial Xray + sing-box/AnyTLS variant;
- link to the exact maintained component repositories and images;
- document compatibility, installation, validation, and known limitations;
- publish unified fork releases that record source commits and immutable image digests;
- point engineering and AI maintenance work to `Cd1s/remnawave-singbox`.

Do not place backend, frontend, or Node runtime code in this repository.

## Upstream synchronization

The scheduled workflow merges `remnawave/panel:main` into `singbox`, validates the documentation,
and pushes only a tested merge. A conflict or failed build leaves the maintained branch unchanged.

When repairing a conflict:

1. Create a temporary branch from `origin/singbox`.
2. Merge `upstream/main`; do not force-push or rebase the public branch.
3. Preserve official documentation updates.
4. Reapply the small fork notice, fork documentation pages, repository links, and fork navigation.
5. Run `npm ci`, `npm run typecheck`, and `npm run build`.
6. Confirm that no official-only deployment workflow requiring unavailable secrets is enabled on
   the fork branch.

## Privacy and release rules

- Never publish real server aliases, addresses, subscription URLs, credentials, user identifiers,
  certificate fingerprints, or production configuration.
- Use immutable image digests in validated releases.
- Do not present this fork as an official Remnawave release.
- Keep Xray compatibility claims tied to test evidence.

## Definition of done

A panel change is complete when documentation builds, links point to the renamed repositories,
fork-specific pages remain easy to find, upstream attribution is intact, and no private deployment
detail is present.
