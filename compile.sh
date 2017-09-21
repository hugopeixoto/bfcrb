#!/usr/bin/env bash

set -e

test -f "$1"

BIN="$(basename "$1")"
BIN="${BIN%.*}"

cat "$1" |
bundle exec bin/bfc |
llc-4.0 -relocation-model=pic |
gcc -o $BIN -x assembler -
