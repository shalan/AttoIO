# External vendor models (gitignored)

Place vendor-supplied Verilog models in this directory when you want
to run AttoIO testbenches against the production-grade device model
instead of AttoIO's in-tree behavioral substitutes.

## AT24C256C (Microchip)

The default I²C EEPROM testbench (`sim/tb_i2c.v`) uses the in-tree
`sim/i2c_eeprom_model.v`, which is a minimal 256-byte, functional-only
substitute (no timing checks).

For tighter verification you can download the Microchip AT24C256C
Verilog model and drop it here as `AT24C256C.v`, then re-run the
testbench with `-DI2C_USE_AT24C256C`. The vendor model is **not**
checked into this repository — it is proprietary IP distributed
separately by Microchip.

Download: https://ww1.microchip.com/downloads/aemDocuments/documents/MPD/ProductDocuments/BoardDesignFiles/AT24C256C.v

Once the file is in place:

```sh
sim/run_i2c.sh EXT=AT24C256C
```

All files in this directory are gitignored (see `.gitignore`).
