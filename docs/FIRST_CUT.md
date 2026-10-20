# First cut on the real CR-1

Coastline has only run against CRWrite's simulated mill so far. Bring it up on the machine in
this order, and **never skip a stage** for a new kind of operation.

The same checklist is in the app: **Projects ▸ First Cut on the CR-1**, with the ticks remembered
and a button for each stage's part in Coastline. It cuts the **First-Cut Coupon** (an example
project: 34 × 24 × 6, facing, the outline, a 14 × 8 × 2.5 pocket, Ø4 and Ø6 holes, a 1.5 mm step;
only tools you own). Wax first (saved with its toolpaths, ~8 min), then POM (40 × 20 bar, ~13 min)
and 6061 (40 × 20 bar, ~23 min): the app switches the stock and generates again. Every feature is a
measuring checkpoint in the guided job, and Record the Result puts them in the journal.

1. **CRWrite basics.** Follow CRWrite's own checklist first: connect, check the DRO, home with `$H`, jog in both modes, and check the soft limits.
2. **Open the guided job.** Export it with *Machining → Export Guided Job for CRWrite…*, then open it in CRWrite and pick the job.
3. **Dry run with no stock and no tool.** Run the helper steps (home, tool-change position) and watch where the spindle goes.
4. **Edge finding on scrap.**
   - Clamp a scrap block and edge-find X and Y.
   - In CRWrite, check that G54 X/Y now sits in the middle of the block. Jog to X0 Y0 to see it.
5. **Touch off and air cut.**
   - Fit the tool at the stick-out shown and touch off.
   - Choose **Yes** for the air cut: the whole program runs 10 mm above the work with the spindle off.
   - Stop if anything moves somewhere unexpected.
6. **First real cut in wax or POM.** Run the cut. Measure at each checkpoint, and note the results.
7. **Aluminium.** Use the same job on 6061, with WD-40 mist and vacuuming between tools.

## Calibration notes to collect
- **Where the table top and spindle nose really are, in machine coordinates.** Home, jog the tool tip to touch the table, then read the DRO. This turns the work-area volume in Coastline's viewport from approximate into exact.
- **The real `$110`–`$112` and `$120`–`$122` values (`$$` in the console).** Coastline's time estimates use the firmware defaults.
- **Spindle power in practice.** Note any stalls or chatter: depth of cut, stepover, material.
