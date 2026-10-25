#!/bin/sh
# Wall time and peak RAM (macOS /usr/bin/time -l) for both 1000x1000 apps.
cd "$(dirname "$0")"
[ -x silica_app/actor_msgs ] || ./silica_app/build.sh >/dev/null 2>&1
erlc -o erlang_app erlang_app/actor_msgs.erl
for app in silica erlang; do
  echo "== $app"
  if [ $app = silica ]; then CMD="./silica_app/actor_msgs"
  else CMD="erl -noshell -pa erlang_app -s actor_msgs main -s init stop"; fi
  /usr/bin/time -l $CMD 2>&1 | egrep "actors|real|maximum resident|peak memory"
done
