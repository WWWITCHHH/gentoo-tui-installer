#!/usr/bin/env bash
# Build a release tarball from the annotated tag matching VERSION.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)
NAME=gentoo-tui-installer
VERSION=$(<"$ROOT/VERSION")
TAG="v${VERSION}"

die() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "VERSION must be semver without a prefix: ${VERSION}"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "not a Git repository: ${ROOT}"
[[ -z $(git -C "$ROOT" status --porcelain --untracked-files=no) ]] ||
    die "tracked files have uncommitted changes; commit or stash them first"

tag_commit=$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/${TAG}^{commit}") ||
    die "tag ${TAG} does not exist"
head_commit=$(git -C "$ROOT" rev-parse HEAD)
[[ $tag_commit == "$head_commit" ]] ||
    die "tag ${TAG} does not point to HEAD"

if [[ -n ${DIST_DIR:-} ]]; then
    [[ $DIST_DIR == /* ]] || DIST_DIR="${PWD}/${DIST_DIR}"
else
    DIST_DIR="${ROOT}/dist"
fi
mkdir -p -- "$DIST_DIR"
archive="${DIST_DIR}/${NAME}-${VERSION}.tar.gz"

git -C "$ROOT" archive --format=tar.gz \
    --prefix="${NAME}-${VERSION}/" \
    --output="$archive" "$TAG"
[[ -s $archive ]] || die "archive was not created: ${archive}"

(
    cd -- "$DIST_DIR"
    sha256sum -- "$(basename -- "$archive")" >"$(basename -- "$archive").sha256"
)

printf 'release: %s\n' "$archive"
printf 'release: %s\n' "${archive}.sha256"
