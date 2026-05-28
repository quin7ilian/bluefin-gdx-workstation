# Silent starter curves — WRX80 Creator R2.0 + Fractal Torrent

Reference curve points for each fan channel. Configure these in the
CoolerControl UI (http://localhost:11987 → Devices → custom-device →
each fan channel → Speed mode: Profile → Graph editor).

These are conservative *starting* points designed to be near-silent at
idle/light load while still having enough headroom to ramp up
aggressively on real thermal load. Tune in the UI based on your
workloads and observed temps under sustained use.

## CPU cooler (FAN1)

| Driver temp | TEMP_CPU |
|---|---|
| Curve type | Graph |
| Points (°C → duty%) | 40 → 25, 60 → 35, 75 → 55, 85 → 100 |

Rationale: stock BMC curve was aggressive (CPU_FAN1 at 80% with TEMP_CPU
in mid-70s). This trades some thermal margin for quiet — sustained heavy
Threadripper load on AVX will push CPU into the 75–85°C zone and the
curve ramps hard there; for light dev/idle the fan stays near 25%.

## Rear exhaust (FAN2 = CPU_OPT)

| Driver temp | TEMP_CPU |
|---|---|
| Curve type | Graph |
| Points (°C → duty%) | 40 → 25, 60 → 35, 75 → 55, 85 → 90 |

Mirrors CPU cooler trajectory but tops out at 90% — rear exhaust adds
diminishing return past that. The Torrent's airflow design pushes most
heat out the top/back; this fan supplements.

## Bottom hub (FAN3 — 3× Dynamic X2 GP-18, 180mm)

| Driver temp | combined: max(TEMP_CPU, TEMP_VRM) |
|---|---|
| Curve type | Graph |
| Points (°C → duty%) | 40 → 20, 60 → 30, 75 → 50, 85 → 85 |

180mm fans move enormous air at low duty. 20% (≈300 RPM) is essentially
silent and still pushes meaningful airflow. Driven by VRM as well as CPU
because the bottom intake feeds straight up through the VRM heatsink
region of a Torrent.

## Top front (FAN4 — single Dynamic X2 GP-14, 140mm)

| Driver temp | combined: max(TEMP_CPU, TEMP_DDR4_max) |
|---|---|
| Curve type | Graph |
| Points (°C → duty%) | 40 → 20, 60 → 30, 75 → 45, 85 → 80 |

Front intake feeds CPU + DIMMs. TEMP_DDR4_max input matters here because
DIMM temps hit 60°C+ before CPU does on memory-bound workloads.

## Bottom front (FAN5 — single Dynamic X2 GP-14, 140mm)

| Driver temp | combined: max(TEMP_CPU, TEMP_DDR4_max) |
|---|---|
| Curve type | Graph |
| Points (°C → duty%) | 40 → 20, 60 → 30, 75 → 45, 85 → 80 |

Same as top front. Both front fans together should track DIMM thermals.

## Combined temp helpers (CoolerControl "Mix" function)

CoolerControl supports composite temperature sources. For the
`max(TEMP_X, TEMP_Y, ...)` curves above:

1. UI → Speed → "Mix" function → "Max"
2. Select source temp channels (e.g., CPU + VRM, or CPU + all 8 DDR4_X)
3. Name the resulting virtual temp (e.g., "ChassisLoad") so curve graphs
   show meaningful labels.

For "DDR4_max", build a Mix(Max) over all 8 DDR4_A..H sensors as a
helper temp, then use that as input to the front fan curves.

## Tuning notes

- Start the system idle and measure baseline temps. If CPU idles at
  40°C, the 40°C floor point in the curves above keeps fans near
  silent.
- Run a sustained workload (e.g., `stress-ng --cpu 64 --timeout 5m`)
  and watch how high temps climb. If TEMP_CPU never crosses 75°C even
  on heavy load, you can lower the 75→55% point and the 85→100% point
  ceiling for quieter sustained operation.
- The wrapper clamps anything below 5% to 5%. If you want a true "off"
  for cosmetic reasons (e.g., zero-RPM-at-idle on a quiet hour), the
  BMC's `Invalid data field` will reject 0/1% writes — so 5% is the
  practical minimum on this hardware.
