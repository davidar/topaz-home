#!/usr/bin/env bash
# Static checks for this repository — the single definition shared by the
# Lint workflow and the pre-commit hook, so the two cannot drift.
#
#     bash tests/lint.sh            # from any checkout (or exported index)
#
# bin/ mixes shell and Python; each file is checked by the tool its
# shebang names, so a new script of either kind is never skipped.
# actionlint runs when installed (the hook insists on it: GitHub rejects
# an invalid workflow file outright, disabling CI until it is fixed);
# set LINT_REQUIRE_ACTIONLINT=1 to fail instead of skip when absent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

just --unstable --fmt --check

shell=()
for f in bin/* tests/*.sh; do
    case "$(head -n 1 "$f")" in
        *python3*) python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" ;;
        *)
            bash -n "$f"
            shell+=("$f")
            ;;
    esac
done
shellcheck "${shell[@]}"

if command -v actionlint > /dev/null; then
    actionlint .github/workflows/*.yml
elif [ "${LINT_REQUIRE_ACTIONLINT:-0}" = 1 ]; then
    echo "lint: actionlint not found; install it (e.g. brew install actionlint)" >&2
    exit 1
else
    echo "lint: actionlint not installed, workflow files not checked" >&2
fi
echo "lint: ok"
