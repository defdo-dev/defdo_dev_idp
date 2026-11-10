#!/bin/sh
# Fails when the dev IdP is present in a production artifact. Fails closed.
#
# usage: assert-no-dev-idp.sh release <release-dir>   (no mix needed; run on the release tree or inside the image)
#        assert-no-dev-idp.sh deps                    (needs mix; run where MIX_ENV=prod deps are fetched)
set -eu
mode="${1:?mode: release|deps}"
case "$mode" in
  release)
    dir="${2:?release dir}"
    [ -d "$dir/lib" ] || { echo "assert-no-dev-idp[release-dir]: not found: $dir" >&2; exit 1; }
    if find "$dir/lib" -name 'Elixir.Defdo.DevIdp*.beam' | grep -q .; then
      echo "assert-no-dev-idp[beams]: Defdo.DevIdp beams present in $dir" >&2; exit 1; fi
    if find "$dir/lib" -maxdepth 1 -name 'defdo_dev_idp-*' | grep -q .; then
      echo "assert-no-dev-idp[app-dir]: defdo_dev_idp application present in $dir/lib" >&2; exit 1; fi
    echo "assert-no-dev-idp: ok (release $dir)";;
  deps)
    if ! out=$(MIX_ENV=prod mix deps.tree --only prod 2>&1); then
      echo "assert-no-dev-idp[deps-tree]: mix deps.tree failed:" >&2; printf '%s\n' "$out" >&2; exit 1; fi
    if printf '%s\n' "$out" | grep -q 'defdo_dev_idp'; then
      echo "assert-no-dev-idp[deps-tree]: defdo_dev_idp is in the prod dependency tree" >&2; exit 1; fi
    echo "assert-no-dev-idp: ok (deps)";;
  *) echo "assert-no-dev-idp[usage]: unknown mode $mode" >&2; exit 2;;
esac
