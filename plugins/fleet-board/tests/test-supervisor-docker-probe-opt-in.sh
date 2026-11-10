#!/bin/bash
set -eu
unset CDPATH
HERE=$(cd "$(dirname "$0")" && pwd)
[[ ! -e "$HERE/test-supervisor-docker-host.sh" ]]
[[ -x "$HERE/probe-supervisor-docker-host.sh" ]]
