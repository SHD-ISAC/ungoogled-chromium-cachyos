#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/container-common.sh
source /recipe/scripts/container-common.sh

bootstrap_pacman \
    git python python313 python-httplib2 python-pyparsing python-six python-requests \
    python-urllib3 python-idna python-yaml python-lxml python-pygments \
    python-pytest python-coverage python-packaging python-brotli \
    python-hjson python-parameterized python-colorama python-sqlparse \
    python-pluggy python-iniconfig npm rsync
depot_python

cd /work
/recipe/fetch-chromium-release "$CHROMIUM_VERSION"
touch "chromium-$CHROMIUM_VERSION/.ungoogled-chromium-cache-complete"
