# cc-plugin-custom-device channels — what `install-cc-plugin` configures

`ujust install-cc-plugin` deploys a pre-populated config to
`/etc/coolercontrol/plugins/custom-device/config.json` defining the
device, fan channels, and temperature sensors below. This document
describes the deployed state; the *source of truth* is the JSON file
itself.

To customize: edit `/etc/coolercontrol/plugins/custom-device/config.json`
(JSON; `_comment_*` keys are ignored by the plugin and can be used for
your own notes), then `sudo systemctl restart coolercontrold`.

The template is at `/usr/share/cc-bmc-bridge/config.json`. `install-cc-plugin`
skip-if-exists, so re-running it never clobbers customizations.

## Device

| id | label |
|---|---|
| `wrx80-bmc` | WRX80 BMC |

## Fan channels (5 controllable, BMC FAN indexes 1–5)

| Channel id | Label | BMC sensor | Physical | set_duty target |
|---|---|---|---|---|
| `cpu_fan` | CPU Fan | CPU_FAN1 | CPU cooler | FAN1 |
| `rear_exhaust` | Rear exhaust | CPU_FAN2/WP | rear case fan | FAN2 |
| `bottom_hub` | Bottom hub (3× GP-18) | CHA_FAN1/WP | 3-fan bottom intake | FAN3 |
| `top_front` | Top front (GP-14) | CHA_FAN2/WP | top front intake | FAN4 |
| `bottom_front` | Bottom front (GP-14) | CHA_FAN3/WP | bottom front intake | FAN5 |

All five channels use `/usr/libexec/cc-set-fan-duty.sh <idx> {duty}` for
PWM writes. The wrapper enforces a 5% BMC-validation floor (see script
header for rationale).

## Temperature sensors (12, read-only)

| Sensor id | Label | IPMI sensor |
|---|---|---|
| `cpu` | CPU | TEMP_CPU |
| `vrm` | VRM | TEMP_VRM |
| `motherboard` | Motherboard | TEMP_MB |
| `lan_ambient` | 10G LAN ambient | TEMP_10G_LAN_AMB |
| `ddr4_a` … `ddr4_h` | DDR4 A … H | TEMP_DDR4_A … TEMP_DDR4_H |

Temperature commands output millidegrees Celsius (CoolerControl's expected
unit; achieved via `awk '... print $4*1000'`). The plugin's executor has a
fallback that divides by 1000 if the value is > 1000, so even plain-°C
output would still work.

## Channels deliberately NOT configured (iteration 1)

| BMC index | IPMI sensor | Reason |
|---|---|---|
| FAN6 | SB_FAN1 | Chipset fan (board-internal). BMC default curve in iteration 1. |
| FAN7 | MOS_FAN1 | VRM fan (board-internal). BMC default curve in iteration 1. |

If you want to add these later: append a new channel entry to
`config.json` using `/usr/libexec/cc-set-fan-duty.sh 6 {duty}` (or 7),
then widen the wrapper's `fan_idx` validation (currently rejects ≠ 1-5,
deliberately, so a misconfigured curve cannot accidentally touch board
fans). Configure a conservative TEMP_VRM-driven curve with a generous
floor (≥40%) for MOS_FAN1, and TEMP_MB-driven for SB_FAN1.
