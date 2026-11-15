# list_literal_from_atom_case_addition

One trial, in its own directory so its atoms (`:all`) do not renumber list_addition's goldens:
`list_literal_returned_from_atom_case`, a function whose body is a case over an atom with a list literal
in each arm, its `List[uint32]` (and a `List[int64]`) returned to the caller. On the boards the frame copier
walked a list's chunks with CDATA = 2 * slot bytes instead of max(16, slot bytes), so a 4-byte element
list faulted (`[silica] fault`, addr 0x16, in rt_state.S `rt_sm_val`); fixed 2026-11-10 in both board
runtimes. Found by the board pin-builtin tests (`compiler/src/emitter/<TARGET>/board/tests/pins`).

`list_uint32_across_chunks`: a 9-element `List[uint32]` (three chunks) returned and summed. The STM32
runtime stored every scalar list element as two words, so a 4-byte element overwrote its neighbour and a
chunk's next word (rt_list.S `rt_list_store_element`); fixed 2026-11-10 to store at the slot's width.
