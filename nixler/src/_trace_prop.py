import lldb
import struct

_state = {"n": 0}


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "command script add -f _trace_prop.on_pass_entry on_pass_entry"
    )


def on_pass_entry(frame, bp_loc, dict):
    """Breakpoint callback: print list length; stop after 25 frames."""
    _state["n"] += 1
    n = _state["n"]
    x0 = frame.FindRegister("x0").GetValueAsUnsigned()
    sp = frame.GetSP()
    err = lldb.SBError()
    b = frame.GetThread().GetProcess().ReadMemory(x0, 8, err)
    ln = struct.unpack("<Q", b)[0] if b else -1
    print(f"PASS {n} len={ln} sp={sp:#x}")
    if n >= 25:
        print("STOP_DEEP")
        return True  # stop
    return False  # continue
