#!/usr/bin/env bash
# For the release workflow: refuse to attach binaries to a release that they
# are not the build of. On a pushed tag the checkout IS the tag and there is
# nothing to check. On a manual run for an existing tag the checkout is the
# default branch, which carries the packaging files the old tag does not, so
# the engine itself (lib/) must be byte-identical to the tag's and mix.exs
# must carry the tag's version.
set -eu

tag=${1:?usage: check_tag.sh <tag>}

if [ "${GITHUB_EVENT_NAME:-}" != "workflow_dispatch" ]; then
  echo "Pushed tag $tag: the checkout is the tag."
  exit 0
fi

git rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
  { echo "::error::there is no tag $tag in this repository"; exit 1; }

version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs | head -n 1)
if [ "v$version" != "$tag" ]; then
  echo "::error::mix.exs says $version, the tag is $tag: binaries built here would not be $tag"
  exit 1
fi

if ! git diff --quiet "$tag" HEAD -- lib; then
  echo "::error::lib/ differs between $tag and the checkout; the binaries would not be $tag"
  git diff --stat "$tag" HEAD -- lib
  exit 1
fi

echo "$tag: mix.exs version matches and lib/ is identical to the tag's."
