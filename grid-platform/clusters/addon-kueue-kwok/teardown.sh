#!/usr/bin/env bash
exec bash "$(git rev-parse --show-toplevel)/clusters/grid-core/addons/kueue-kwok/teardown.sh" "$@"
