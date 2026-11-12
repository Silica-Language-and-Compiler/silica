#!/usr/bin/env python3
"""Writes the (:memory) storage-carrier trial programs of trials/transport_addition/app_transport_store_memory.
usage: gen_store_trials.py OUTDIR [--direct]
--direct spawns the carrier module by name (for a compiler without the (:store) kind).
Each program is a scripted owner actor: the script is the list of steps at the end of this file."""
import sys, os

OUT = sys.argv[1]
DIRECT = "--direct" in sys.argv
FS = "{ mode: atom, expected: int64, pending: string }"
ST = "{ car: actor_ref, step: int64, left: int64, rx: %s }" % FS
MSG = "(:link_up, string) | (:log, int64, int64, int64) | (:tx_credit, int64) | (:synced, int64) | (:rx, string) | (:rx_end, int64) | (:tx_failed, atom) | (:read_failed, atom) | (:link_down, atom) | :settled"

COMMON = '''
fn say_n(label: string, n: int64) -> atom {
    sequence proc[device_io]
        _: atom <- print(label);
        _: atom <- print_int64(n);
        o: atom <- println("")
    produces
        pure o
    end
}

fn say_atom(label: string, a: atom) -> atom {
    sequence proc[device_io]
        _: atom <- print(label);
        _: atom <- print_atom(a);
        o: atom <- println("")
    produces
        pure o
    end
}

fn say_text(label: string, s: string) -> atom {
    sequence proc[device_io]
        _: atom <- print(label);
        o: atom <- println(s)
    produces
        pure o
    end
}

fn say_log(oldest: int64, nx: int64, capacity: int64) -> atom {
    sequence proc[device_io]
        _: atom <- print("log oldest=");
        _: atom <- print_int64(oldest);
        _: atom <- print(" next=");
        _: atom <- print_int64(nx);
        _: atom <- print(" capacity=");
        _: atom <- print_int64(capacity);
        o: atom <- println("")
    produces
        pure o
    end
}

fn tx(car: actor_ref, s: string) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, (:tx, s, self()) impl ActorMessage {})
    produces
        pure r
    end
}

// n records of `size` zero bytes each.
fn tx_zeros(car: actor_ref, n: int64, size: int64) -> boolean {
    case n <= 0 of {
        true -> true;
        false -> {
            _: boolean <- tx(car, storelog@zeros(size));
            tx_zeros(car, n - 1, size)
        }
    }
}

fn tx_all(car: actor_ref, segs: List[string, mem(normal)]) -> boolean {
    case segs of {
        []: List[string, mem(normal)] -> true;
        [h: string, t: List[string, mem(normal)]] -> {
            _: boolean <- tx(car, h);
            tx_all(car, t)
        }
    }
}

fn nth(xs: List[string, mem(normal)], i: int64) -> string {
    case xs of {
        []: List[string, mem(normal)] -> "";
        [h: string, t: List[string, mem(normal)]] -> case i == 0 of { true -> h; false -> nth(t, i - 1) }
    }
}

fn ask_sync(car: actor_ref) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, :sync impl ActorMessage {})
    produces
        pure r
    end
}

fn ask_read(car: actor_ref, from: int64) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, (:read, from) impl ActorMessage {})
    produces
        pure r
    end
}

fn ask_read_stop(car: actor_ref) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, :read_stop impl ActorMessage {})
    produces
        pure r
    end
}

fn give_credit(car: actor_ref, n: int64) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, (:credit, n) impl ActorMessage {})
    produces
        pure r
    end
}

fn ask_trim(car: actor_ref, upto: int64) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, (:trim, upto) impl ActorMessage {})
    produces
        pure r
    end
}

fn ask_close(car: actor_ref) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, :close impl ActorMessage {})
    produces
        pure r
    end
}

// The carrier ends after :close and, having no supervisor, its normal exit is reported on standard
// error. The owner waits for that report before it prints the carrier's last message and the line
// the trial run ends at.
fn settle() -> boolean {
    sequence proc[concurrency]
        _: timer_ref <- send_after(300, self(), :settled impl ActorMessage {})
    produces
        pure true
    end
}

fn finished() -> boolean {
    sequence proc[device_io]
        _: atom <- println("link_down :closed");
        _: atom <- println("done")
    produces
        pure true
    end
}

// The script: at each step the owner waits for need(step) events of the kind expect(step), then
// act(step) runs and the next step begins. Every event is printed as it arrives, awaited or not.
fn progress(e: atom, st: ST) -> ST {
    case e == expect(st.step) of {
        false -> st;
        true -> case st.left > 1 of {
            true -> { car: st.car, step: st.step, left: st.left - 1, rx: st.rx };
            false -> acted(st)
        }
    }
}

fn acted(st: ST) -> ST {
    _: boolean <- act(st.step, st.car);
    { car: st.car, step: st.step + 1, left: need(st.step + 1), rx: st.rx }
}

fn on_text(label: string, s: string, e: atom, st: ST) -> (:no_reply, ST) {
    _: atom <- say_text(label, s);
    (:no_reply, progress(e, st))
}

fn on_n(label: string, n: int64, e: atom, st: ST) -> (:no_reply, ST) {
    _: atom <- say_n(label, n);
    (:no_reply, progress(e, st))
}

fn on_atom(label: string, a: atom, e: atom, st: ST) -> (:no_reply, ST) {
    _: atom <- say_atom(label, a);
    (:no_reply, progress(e, st))
}

// The carrier's last message. (:link_down, :closed) is printed by finished(), after the carrier's exit
// report: the report is written by another thread and would otherwise land before or after this line.
fn on_link_down(why: atom, st: ST) -> (:no_reply, ST) {
    case why == :closed of {
        true -> (:no_reply, progress(:link_down, st));
        false -> on_atom("link_down ", why, :link_down, st)
    }
}

fn on_log(oldest: int64, nx: int64, capacity: int64, st: ST) -> (:no_reply, ST) {
    _: atom <- say_log(oldest, nx, capacity);
    (:no_reply, progress(:log, st))
}

fn on_rx(segment: string, st: ST) -> (:no_reply, ST) {
    (:no_reply, progress(:rx, shown(segment, st)))
}

fn owner(msg: MSG, state: ST) -> (:no_reply, ST) {
    case msg of {
        (:link_up, info: string) -> on_text("link_up ", info, :link_up, state);
        (:log, a: int64, b: int64, c: int64) -> on_log(a, b, c, state);
        (:tx_credit, n: int64) -> on_n("tx_credit ", n, :tx_credit, state);
        (:synced, n: int64) -> on_n("synced ", n, :synced, state);
        (:rx, s: string) -> on_rx(s, state);
        (:rx_end, n: int64) -> on_n("rx_end ", n, :rx_end, state);
        (:tx_failed, why: atom) -> on_atom("tx_failed ", why, :tx_failed, state);
        (:read_failed, why: atom) -> on_atom("read_failed ", why, :read_failed, state);
        (:link_down, why: atom) -> on_link_down(why, state);
        :settled -> (:no_reply, progress(:settled, state))
    }
}

fn main() -> int64 {
    sequence proc[concurrency, device_io]
        _: supervisor_ref <- trial_wait_int64@start();
        _: boolean <- trial_wait_int64@run(fn() -> int64 {
            sequence proc[concurrency]
                car: actor_ref <- SPAWN;
                own: actor_ref <- spawn({ car: car, step: 0, left: need(0), rx: wireframe@fresh(:storage) }, owner, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
                _: boolean <- cast(car, (:open, own, "") impl ActorMessage {})
            produces
                pure 0
            end
        });
        code: int64 <- wait_for_exit()
    produces
        pure code
    end
}
'''

SHOWN_RAW = '''
// A replayed record, as it is.
fn shown(segment: string, st: ST) -> ST {
    _: atom <- case length_bytes(segment) < 24 of {
        true -> say_text("rx ", segment);
        false -> say_n("rx bytes=", length_bytes(segment))
    };
    st
}
'''

SHOWN_FRAMED = '''
// A replayed record goes through the :storage framing; a whole frame is shown by show_frame.
fn shown(segment: string, st: ST) -> ST {
    reframed(wireframe@unframe(st.rx, segment, MAXFRAME), st)
}

fn reframed(r: (:more, FS) | (:frame, string, FS) | (:rejected, atom), st: ST) -> ST {
    case r of {
        (:more, rx1: FS) -> more(rx1, st);
        (:frame, f: string, rx2: FS) -> framed(f, rx2, st);
        (:rejected, why: atom) -> rejected(why, st)
    }
}

fn more(rx1: FS, st: ST) -> ST {
    _: atom <- say_n("rx more, waiting for record ", rx1.expected);
    { car: st.car, step: st.step, left: st.left, rx: rx1 }
}

fn framed(f: string, rx2: FS, st: ST) -> ST {
    _: atom <- show_frame(f);
    { car: st.car, step: st.step, left: st.left, rx: rx2 }
}

fn rejected(why: atom, st: ST) -> ST {
    _: atom <- say_atom("rx rejected ", why);
    { car: st.car, step: st.step, left: st.left, rx: wireframe@fresh(:storage) }
}
'''

def script(steps):
    """steps: list of (event, count, action-body or None). Returns expect/need/act functions."""
    exp = "fn expect(step: int64) -> atom {\n    case step of {\n"
    need = "fn need(step: int64) -> int64 {\n    case step of {\n"
    act = "fn act(step: int64, car: actor_ref) -> boolean {\n    case step of {\n"
    fns = ""
    for i, (e, n, body) in enumerate(steps):
        exp += "        %d -> :%s;\n" % (i, e)
        need += "        %d -> %d;\n" % (i, n)
        if body:
            act += "        %d -> act%d(car);\n" % (i, i)
            lines = [l.strip() for l in body.strip().split("\n") if l.strip()]
            fns += "\nfn act%d(car: actor_ref) -> boolean {\n" % i
            for l in lines[:-1]:
                fns += "    _: boolean <- %s;\n" % l
            fns += "    %s\n}\n" % lines[-1]
    exp += "        _: int64 -> :never\n    }\n}\n"
    need += "        _: int64 -> 1\n    }\n}\n"
    act += "        _: int64 -> true\n    }\n}\n"
    return "\n" + exp + "\n" + need + "\n" + act + fns

def trial(name, header, cap, ret, uses, shown, extra, steps, maxframe="65536"):
    spawn = ("spawn(store_memory_carrier@initial(%d, :%s), store_memory_carrier@carrier, stack_policy(0, :keep_last_message), state_policy(:keep_state_area))" % (cap, ret)) if DIRECT else \
            "spawn_dangerous_carrier(journal, stack_policy(0, :keep_last_message), state_policy(:keep_state_area))"
    src = header.strip("\n") + "\nmodule %s;\n\n" % name
    mods = ["wireframe", "Carrier", "storelog"] + uses + ["trial_wait_int64"]
    if DIRECT:
        mods.insert(3, "store_memory_carrier")
    for m in mods:
        src += "use %s;\n" % m
    if not DIRECT:
        src += "\ncarried_on journal: (:store) (:memory, %d, :%s);\n" % (cap, ret)
    body = extra + shown + script(steps) + COMMON
    body = body.replace("SPAWN", spawn).replace("MAXFRAME", maxframe).replace("MSG", MSG).replace("ST", ST).replace("FS", FS)
    if DIRECT:
        body = body.replace("Carrier@mtu(journal)", "Carrier@mtu(:store)").replace("Carrier@boundaries(journal)", "Carrier@boundaries(:store)")
    open(os.path.join(OUT, name + ".silica"), "w").write(src + body)

# ---------------------------------------------------------------------------------------------------
trial("store_append_replay", '''
// The (:store) kind on the (:memory) medium (transport_serialization_design.md §6.8): values are
// appended and replayed. Three values of a sum type are encoded with (:etf), wrapped with
// wireframe@record (format id and schema version 3), framed for the carrier with the kind's own
// properties, Carrier@mtu(journal) and Carrier@boundaries(journal), and sent as :tx. The two
// acknowledgement levels arrive in order: (:tx_credit, 3) when the records leave the write-behind
// buffer, then (:synced, 3) when they are durable. A replay from 0 gives the three records back; each
// is unframed, unwrapped and decoded to the value that was stored. :close ends the carrier, whose
// normal exit is reported on standard error (it has no supervisor).
''', 8192, "stop", ["wire_etf"], SHOWN_FRAMED, '''
fn put(car: actor_ref, v: (:reading, { x: int64, label: string }) | (:note, string)) -> boolean {
    sequence proc[mem(normal), transport]
        body: string <- encode((:etf), v);
        segs: List[string, mem(normal)] <- wireframe@frame(wireframe@record(:etf, 3, body), Carrier@mtu(journal), Carrier@boundaries(journal))
    produces
        pure tx_all(car, segs)
    end
}

fn put_reading(car: actor_ref, x: int64, label: string) -> boolean {
    v: (:reading, { x: int64, label: string }) <- (:reading, { x: x, label: label });
    put(car, v)
}

fn put_note(car: actor_ref, text: string) -> boolean {
    v: (:note, string) <- (:note, text);
    put(car, v)
}

fn show_frame(f: string) -> atom {
    unwrapped(wireframe@unrecord(f))
}

fn unwrapped(r: (:ok, atom, int64, string) | (:rejected, atom)) -> atom {
    case r of {
        (:ok, format: atom, schema: int64, body: string) -> stored(format, schema, body);
        (:rejected, why: atom) -> say_atom("rx unrecord rejected ", why)
    }
}

fn stored(format: atom, schema: int64, body: string) -> atom {
    sequence proc[mem(normal), device_io, transport]
        _: atom <- print("rx format=");
        _: atom <- print_atom(format);
        _: atom <- print(" schema=");
        _: atom <- print_int64(schema);
        _: atom <- print(" ");
        decoded: (:ok, (:reading, { x: int64, label: string }) | (:note, string)) | (:rejected, atom) <- decode((:etf), body, { max_bytes: 256 });
        o: atom <- case decoded of {
            (:ok, v: (:reading, { x: int64, label: string }) | (:note, string)) -> show_value(v);
            (:rejected, why: atom) -> say_atom("decode rejected ", why)
        }
    produces
        pure o
    end
}

fn show_value(v: (:reading, { x: int64, label: string }) | (:note, string)) -> atom {
    case v of {
        (:reading, r: { x: int64, label: string }) -> show_reading(r.x, r.label);
        (:note, text: string) -> say_text("note ", text)
    }
}

fn show_reading(x: int64, label: string) -> atom {
    sequence proc[device_io]
        _: atom <- print("reading x=");
        _: atom <- print_int64(x);
        _: atom <- print(" label=");
        o: atom <- println(label)
    produces
        pure o
    end
}
''', [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, 'put_reading(car, 41, "a")\nput_note(car, "hello")\nput_reading(car, 0 - 5, "b")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 0)\ngive_credit(car, 3)"),
    ("rx", 3, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

# ---------------------------------------------------------------------------------------------------
steps = [("link_up", 1, None), ("log", 1, None)]
for i in range(5):
    steps.append(("tx_credit", 1, "tx_zeros(car, 8, %d)" % (100 + i)))
steps.append(("tx_credit", 1, "ask_sync(car)"))
steps.append(("synced", 1, "ask_read(car, 0)\ngive_credit(car, 3)"))
for i in range(13):
    steps.append(("rx", 3, "give_credit(car, 3)"))
steps.append(("rx_end", 1, "ask_close(car)"))
steps.append(("link_down", 1, "settle()"))
steps.append(("settled", 1, "finished()"))
trial("store_replay_credit", '''
// Credit-paced replay of a log five times the size of the write-behind buffer (design §6.8.2). Forty
// records go in eight at a time: the buffer's eight slots fill, the carrier drains it and hands the
// eight credits back, and the next eight follow (the record length tells the rounds apart: 100 to
// 104 bytes). After a :sync the owner replays from 0 with three receive credits at a time: three
// (:rx, ...) arrive and the replay waits until the next (:credit, 3), as a TCP receive window paces a
// sender, to (:rx_end, 40). Every grant here is exactly what
// the owner then receives: receive credit left over when a replay ends is still good for the next one.
''', 65536, "stop", [], SHOWN_RAW, "", steps)

# ---------------------------------------------------------------------------------------------------
trial("store_large_value", '''
// A value larger than the carrier's largest record (design §6.8.3): a 10000-byte string encodes to one
// (:etf) frame of about 10 KB, which wireframe cuts into three records of at most
// Carrier@mtu(journal) = 4064 bytes, each headed by the :storage segment header. The replay hands the
// three records back and wireframe@unframe joins them: two "more", then the frame, which decodes to
// the stored string. One value is one frame and is held whole in memory; data larger than memory is a
// stream of values.
''', 65536, "stop", ["wire_etf"], SHOWN_FRAMED, '''
fn put_blob(car: actor_ref, size: int64) -> boolean {
    sequence proc[mem(normal), transport]
        v: (:blob, string) <- (:blob, storelog@zeros(size));
        body: string <- encode((:etf), v);
        segs: List[string, mem(normal)] <- wireframe@frame(wireframe@record(:etf, 1, body), Carrier@mtu(journal), Carrier@boundaries(journal))
    produces
        pure tx_all(car, segs)
    end
}

fn show_frame(f: string) -> atom {
    unwrapped(wireframe@unrecord(f))
}

fn unwrapped(r: (:ok, atom, int64, string) | (:rejected, atom)) -> atom {
    case r of {
        (:ok, _format: atom, _schema: int64, body: string) -> stored(body);
        (:rejected, why: atom) -> say_atom("rx unrecord rejected ", why)
    }
}

fn stored(body: string) -> atom {
    sequence proc[mem(normal), transport]
        decoded: (:ok, (:blob, string)) | (:rejected, atom) <- decode((:etf), body, { max_bytes: 16384 });
        o: atom <- case decoded of {
            (:ok, v: (:blob, string)) -> show_blob(v);
            (:rejected, why: atom) -> say_atom("decode rejected ", why)
        }
    produces
        pure o
    end
}

fn show_blob(v: (:blob, string)) -> atom {
    case v of {
        (:blob, s: string) -> say_n("rx frame: blob bytes=", length_bytes(s))
    }
}
''', [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, "put_blob(car, 10000)\nask_sync(car)"),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 0)\ngive_credit(car, 3)"),
    ("rx", 3, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

# ---------------------------------------------------------------------------------------------------
trial("store_ring", '''
// The :ring retention mode on a region of two 4096-byte blocks (design §6.8.5): writing never stops,
// the oldest block is reclaimed and `oldest` advances. Three small records and a :sync, replayed whole;
// then eight 1000-byte records wrap the ring (four fit in a block), so the block that held 0 to 5 is
// reclaimed and the log holds 6 to 10. A reader behind `oldest` is refused: (:read, 0) answers
// (:read_failed, :trimmed) and a (:log, ...) with the new numbers. A replay from 6 is given two
// credits and waits; eight more records reclaim both blocks under it (oldest becomes 14), and the next
// credit ends that replay with :trimmed too. The records of an earlier lap still lie in a reclaimed
// block behind the new ones; their sequence numbers end the block, never their checks.
''', 8192, "ring", [], SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, 'tx(car, "r0")\ntx(car, "r1")\ntx(car, "r2")\nask_sync(car)'),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 0)\ngive_credit(car, 3)"),
    ("rx", 3, None),
    ("rx_end", 1, "tx_zeros(car, 8, 1000)"),
    ("tx_credit", 1, "ask_trim(car, 0)"),
    ("log", 1, "ask_read(car, 0)"),
    ("read_failed", 1, None),
    ("log", 1, "ask_read(car, 6)\ngive_credit(car, 2)"),
    ("rx", 2, "tx_zeros(car, 8, 1000)"),
    ("tx_credit", 1, "give_credit(car, 1)"),
    ("read_failed", 1, None),
    ("log", 1, "ask_read(car, 14)\ngive_credit(car, 5)"),
    ("rx", 5, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

# ---------------------------------------------------------------------------------------------------
trial("store_stop", '''
// The :stop retention mode on a region of one 4096-byte block (design §6.8.5): nothing is ever
// overwritten. Four 1000-byte records fill the block; the fifth is refused with (:tx_failed, :full)
// and takes no number, so a :sync answers (:synced, 4). A (:trim, 4) is accepted in every mode but the
// tail block is never released, so the (:log, ...) still says oldest 0 and the region stays full. The
// four records are all there to replay.
''', 4096, "stop", [], SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, "tx_zeros(car, 5, 1000)"),
    ("tx_failed", 1, "ask_sync(car)"),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_trim(car, 4)"),
    ("log", 1, "tx_zeros(car, 1, 1000)"),
    ("tx_failed", 1, "ask_read(car, 0)\ngive_credit(car, 4)"),
    ("rx", 4, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

# ---------------------------------------------------------------------------------------------------
trial("store_trim", '''
// The :trim retention mode on a region of two 4096-byte blocks, used as a durable queue (design
// §6.8.5): a consumer reads, then trims. Eight 1000-byte records fill both blocks and a ninth is
// refused with :full. The consumer replays four records, stops the replay early with :read_stop
// ((:rx_end, 4): the first record not delivered) and sends (:trim, 4): the first block lies wholly
// below 4 and is released, answered by (:log, 4, 8, ...). The ninth record now fits. A (:trim, 6)
// releases nothing, because the block that holds 4 to 7 does not lie wholly below 6: the answer still
// says oldest 4, and a consumer that reads from `oldest` sees 4 and 5 again. A trimmed queue delivers
// at least once.
''', 8192, "trim", [], SHOWN_RAW, "", [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, "tx_zeros(car, 8, 1000)"),
    ("tx_credit", 1, "tx_zeros(car, 1, 1000)"),
    ("tx_failed", 1, "ask_read(car, 0)\ngive_credit(car, 4)"),
    ("rx", 4, "ask_read_stop(car)"),
    ("rx_end", 1, "ask_trim(car, 4)"),
    ("log", 1, "tx_zeros(car, 1, 1001)\nask_sync(car)"),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_trim(car, 6)"),
    ("log", 1, "ask_read(car, 4)\ngive_credit(car, 5)"),
    ("rx", 5, None),
    ("rx_end", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
])

# ---------------------------------------------------------------------------------------------------
trial("store_replay_control", '''
// Replay over what a real log holds, and the refusals of the vocabulary (design §6.8.2, §6.8.3).
// Frames are cut for a 12-byte record so that "alpha-alpha-alpha" is three records (A0, A1, A2) and
// "bravo" is one (B0). The log is written as A0 A1 | B0 | A0 A1 A2: the first two records are the front
// of a frame whose end never arrived, as after a crash in the middle of a frame.
//   - A replay from 0 drops the orphaned front when the next frame-start record arrives and gives
//     "bravo", then the whole "alpha-alpha-alpha".
//   - A replay from 4 lands inside a frame: records 4 and 5 (A1, A2) continue nothing and are skipped.
//   - One replay at a time: a (:read, 2) during a replay is (:read_failed, :busy); :read_stop ends the
//     replay with (:rx_end, 1), the first record not delivered.
//   - A second (:open, ...) of an open region is answered (:link_down, :in_use) and changes nothing.
//   - (:read, 99) is :beyond_tail; an empty record is refused with :empty and a 5000-byte one with
//     :too_long, and neither takes a number: the (:synced, 6) that follows says so.
''', 16384, "stop", [], SHOWN_FRAMED, '''
fn alpha() -> List[string, mem(normal)] {
    wireframe@frame("alpha-alpha-alpha", 12, :storage)
}

fn bravo() -> List[string, mem(normal)] {
    wireframe@frame("bravo", 12, :storage)
}

fn show_frame(f: string) -> atom {
    say_text("rx frame ", f)
}

fn open_again(car: actor_ref) -> boolean {
    sequence proc[concurrency]
        r: boolean <- cast(car, (:open, self(), "") impl ActorMessage {})
    produces
        pure r
    end
}
''', [
    ("link_up", 1, None),
    ("log", 1, None),
    ("tx_credit", 1, "tx(car, nth(alpha(), 0))\ntx(car, nth(alpha(), 1))\ntx_all(car, bravo())\ntx_all(car, alpha())\nask_sync(car)"),
    ("tx_credit", 1, None),
    ("synced", 1, "ask_read(car, 0)\ngive_credit(car, 6)"),
    ("rx", 6, None),
    ("rx_end", 1, "ask_read(car, 4)\ngive_credit(car, 2)"),
    ("rx", 2, None),
    ("rx_end", 1, "ask_read(car, 0)\ngive_credit(car, 1)"),
    ("rx", 1, "ask_read(car, 2)"),
    ("read_failed", 1, "ask_read_stop(car)"),
    ("rx_end", 1, "open_again(car)"),
    ("link_down", 1, "ask_read(car, 99)"),
    ("read_failed", 1, 'tx(car, "")'),
    ("tx_failed", 1, "tx(car, storelog@zeros(5000))"),
    ("tx_failed", 1, "ask_sync(car)"),
    ("synced", 1, "ask_close(car)"),
    ("link_down", 1, "settle()"),
    ("settled", 1, "finished()"),
], maxframe="64")
print("written to", OUT)
