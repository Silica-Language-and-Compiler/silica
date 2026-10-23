#!/bin/sh
set -e
cd "$(dirname "$0")"
erlc actor_msgs.erl
erl -noshell -s actor_msgs main -s init stop
