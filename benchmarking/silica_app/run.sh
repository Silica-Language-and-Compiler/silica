#!/bin/sh
cd "$(dirname "$0")"
[ -x actor_msgs ] || ./build.sh
time ./actor_msgs
