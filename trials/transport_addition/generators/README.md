# Generators for the storage-carrier trial programs

The programs of `app_transport_store_memory/` and `app_transport_store_backing/` are scripted owner actors: each
waits for a number of events of one kind, acts, and goes on to the next step. The owner's text is the same in every
program, so the programs are written from a list of steps each.

```
python3 gen_store_trials.py   ../app_transport_store_memory     # seven programs on (:memory)
python3 gen_backing_trials.py ../app_transport_store_backing    # six programs on (:backing)
```

`gen_backing_trials.py` takes the shared owner text from `gen_store_trials.py`, which must lie beside it. A step is
`(event, count, actions)`: after `count` events of that kind the actions run (one call per line). The `.silica`
files are what the trials compile and what is committed; after changing a script, regenerate, rerun the sub-trial and
refresh its goldens.

Things a script must respect:

- Receive credit outlives a replay, so grant exactly the credit the script expects to be used.
- A carrier that ends reports its exit on standard error from another thread. Send `:close`, wait for
  `:link_down`, then `settle()`; print the last lines on `:settled`.
- A program that is run twice on a surviving backing ends its replays with `:read_stop`.
- A program that starts a `(:backing)` carrier is named `dangerous_` (E4021).
