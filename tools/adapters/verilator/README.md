# Verilator capture adapter

Wire `trace_contract.hpp` into the existing testbench at the exact RTL semantic phase documented in
`docs/OBSERVABILITY.json`. The adapter writes raw native events; `tools/mister.py` performs strict
normalization.

The simulation receives:

- `MISTER_TRACE_OUT`
- `MISTER_INPUT_FILE`
- `MISTER_SCENARIO`
- `MISTER_SEED`
- `MISTER_STOP_KIND`
- `MISTER_STOP_VALUE`

Recommended sampling rule for a bus domain:

```cpp
if (posedge && accepted_transfer) {
    writer.emit_bus("mainbus", "completed", write ? 'W' : 'R',
                    native_address, native_data, native_byte_enable);
}
```

Do not emit the request on one side and completion on the other. Do not call `eval()` with testbench
inputs changing on the same edge unless the intended setup/hold order is explicit. For multiple
clocks, maintain a separate sequence counter per domain unless a global canonical timestamp is
proved.

Start with architectural events and checkpoint hashes. Add a narrow FST only around a localized
divergence. Use Verilator reset/X-initial seed variation, then a four-state simulator when
initialization or scheduling remains ambiguous.
