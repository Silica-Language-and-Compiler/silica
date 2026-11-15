#!/usr/bin/env python3
"""Writes the (:backing) storage-carrier trial programs of trials/transport_addition/app_transport_store_backing.
usage: gen_backing_trials.py OUTDIR
It takes the shared owner-actor text from gen_store_trials.py, which must lie beside it."""
import sys, os, re
SP = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1]
head = open(os.path.join(SP, "gen_store_trials.py")).read().split("# -----")[0]
head = head.replace("OUT = sys.argv[1]", "").replace('DIRECT = "--direct" in sys.argv', "DIRECT = False")
exec(head)
CAR = "dangerous_actor_ref"

EXTRA = '''
// A new carrier on the same declaration, opened by this owner: a restart of the carrier actor.
fn fresh() -> CAR {
    sequence proc[concurrency]
        c: CAR <- spawn_dangerous_carrier(journal, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        _: boolean <- cast(c, (:open, self(), "") impl ActorMessage {})
    produces
        pure c
    end
}

fn next_car(step: int64, car: CAR) -> CAR {
    case step == RESTART_AT of {
        true -> fresh();
        false -> car
    }
}

fn said_closed() -> boolean {
    sequence proc[device_io]
        _: atom <- println("link_down :closed")
    produces
        pure true
    end
}

fn done_only() -> boolean {
    sequence proc[device_io]
        _: atom <- println("done")
    produces
        pure true
    end
}
'''

def btrial(name, header, path, cap, ret, shown, extra, steps, respawn=-1):
    src = header.strip("\n") + "\nmodule %s;\n\n" % name
    for m in ["wireframe", "Carrier", "storelog", "trial_wait_int64"]:
        src += "use %s;\n" % m
    src += '\ncarried_on journal: (:store) (:backing, "%s", %d, :%s);\n' % (path, cap, ret)
    body = extra + EXTRA + shown + script(steps) + COMMON
    body = body.replace("SPAWN", "spawn_dangerous_carrier(journal, stack_policy(0, :keep_last_message), state_policy(:keep_state_area))")
    body = body.replace("MAXFRAME", "65536").replace("MSG", MSG).replace("RESTART_AT", str(respawn))
    body = body.replace("{ car: st.car, step: st.step + 1, left: need(st.step + 1), rx: st.rx }", "{ car: next_car(st.step, st.car), step: st.step + 1, left: need(st.step + 1), rx: st.rx }")
    body = body.replace("ST", ST).replace("FS", FS)
    body = body.replace("car: actor_ref", "car: " + CAR).replace("CAR", CAR)
    open(os.path.join(OUT, name + ".silica"), "w").write(src + body)

btrial("dangerous_store_backing_restart", '''
// The (:store) kind on a hosted backing (transport_serialization_design.md §6.8, phase S1): what is
// stored survives the carrier. Three records and a :sync, two more and a :sync (the second pair lies
// at the next write-unit boundary: a sync never rewrites its unit), then :close, which ends the
// carrier. A NEW carrier is then started on the same declaration, as after a restart: it opens the
// backing, reads the block headers, counts the tail block's records and reports the log it found,
// (:log, 0, 5, ...). A replay from 0 gives all five records back. A sixth is appended and synced, and a
// replay from 3 gives r3, r4 and r5.
//
// The trial run starts from no backing (make_backings.py removes it). Run a second time, as a second
// process on the backing the first run left, the same program finds six records at its first open and
// reads the first run's r0 to r4: that run is the Makefile's last step, compared with
// dangerous_store_backing_restart.second.scout. Each replay is ended with :read_stop after the records
// the script asked for, which changes nothing in the first run (the replay is already over there) and
// ends it in the second, where the log goes on past them.
''', "store_backing_restart.sildat", 8192, "stop", SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, 'tx(car, "r0")\ntx(car, "r1")\ntx(car, "r2")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, 'tx(car, "r3")\ntx(car, "r4")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "said_closed()"),
    ("link_up", 1, None),
    ("log", 1, "ask_read(car, 0)\ngive_credit(car, 5)"),
    ("rx", 5, "ask_read_stop(car)"),
    ("rx_end", 1, 'tx(car, "r5")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 3)\ngive_credit(car, 3)"),
    ("rx", 3, "ask_read_stop(car)"),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
], respawn=8)

btrial("dangerous_store_backing_torn", '''
// A torn tail (design §6.8.4, §6.8.5). The backing holds three good records and the first 20 bytes of
// a fourth, as after a power loss in the middle of a write (make_backings.py writes it). The open ends
// the log at the torn record: (:log, 0, 3, ...). A replay gives the three records. A new record is
// then appended: it is written at the next write-unit boundary, never over the torn bytes, takes the
// number 3, and a replay from 3 finds it there.
''', "store_backing_torn.sildat", 8192, "stop", SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, "ask_read(car, 0)\ngive_credit(car, 3)"),
    ("tx_credit", 1, None),
    ("rx", 3, None),
    ("rx_end", 1, 'tx(car, "after")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 3)\ngive_credit(car, 1)"),
    ("rx", 1, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

btrial("dangerous_store_backing_flipped", '''
// A flipped byte in the middle of a log (design §6.8.4). The backing holds records 0 to 2 in its first
// block and 3 and 4 in its second, the tail; one byte of record 1's payload is wrong
// (make_backings.py). The open counts the tail block only, so it reports (:log, 0, 5, ...). A replay
// from 0 gives record 0 and then stops with (:read_failed, :corrupt): record 1 fails its check, and
// the carrier never skips a bad record, because what follows it in the block is not trusted. The
// records of the next block are still there for a reader that starts at 3.
''', "store_backing_flipped.sildat", 8192, "stop", SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, "ask_read(car, 0)\ngive_credit(car, 5)"),
    ("tx_credit", 1, None),
    ("rx", 1, None),
    ("read_failed", 1, "ask_read(car, 3)"),
    ("rx", 2, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

btrial("dangerous_store_backing_stale", '''
// Records of an earlier lap after the tail (design §6.8.4). The one-block :ring backing was reused: its
// header says the block begins at record 10, records 10 and 11 follow, and right behind them lie two
// records of the lap before, numbers 2 and 3, whole and with good checks (make_backings.py). Their
// numbers end the log, not their checks: the open reports (:log, 10, 12, ...) and a replay gives 10 and
// 11 only. Record 12 is then appended at the next write-unit boundary, and a replay gives 10, 11 and 12.
''', "store_backing_stale.sildat", 4096, "ring", SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, "ask_read(car, 10)\ngive_credit(car, 2)"),
    ("tx_credit", 1, None),
    ("rx", 2, None),
    ("rx_end", 1, 'tx(car, "new12")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 10)\ngive_credit(car, 3)"),
    ("rx", 3, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

btrial("dangerous_store_backing_mismatch", '''
// A backing of another size (design §6.8.1). The backing exists at 4096 bytes (make_backings.py) and the
// declaration says 8192: it is not resized, and the open is refused with (:link_down, :mismatch).
''', "store_backing_mismatch.sildat", 8192, "stop", SHOWN_RAW, "", [
    ("link_down", 1, "done_only()"),
])

btrial("dangerous_store_backing_in_use", '''
// One owner per region, held by a lock on the backing (design §6.8.2). While the first carrier has the
// backing open, a second carrier started on the same declaration is refused with
// (:link_down, :in_use): its open finds the backing locked, as a second process's would.
''', "store_backing_in_use.sildat", 8192, "stop", SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, None),
    ("link_down", 1, "done_only()"),
], respawn=2)
print("written to", OUT)
