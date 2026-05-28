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

## Fan channels (7 controllable, BMC FAN indexes 1–7)

| Channel id | Label | BMC sensor | Physical | set_duty target |
|---|---|---|---|---|
| `cpu_fan` | CPU Fan | CPU_FAN1 | CPU cooler | FAN1 |
| `rear_exhaust` | Rear exhaust | CPU_FAN2/WP | rear case fan | FAN2 |
| `bottom_hub` | Bottom hub (3× GP-18) | CHA_FAN1/WP | 3-fan bottom intake | FAN3 |
| `top_front` | Top front (GP-14) | CHA_FAN2/WP | top front intake | FAN4 |
| `bottom_front` | Bottom front (GP-14) | CHA_FAN3/WP | bottom front intake | FAN5 |
| `sb_fan` | Chipset (SB_FAN1) | SB_FAN1 | board-internal chipset fan | FAN6 |
| `mos_fan` | VRM (MOS_FAN1) | MOS_FAN1 | board-internal VRM fan | FAN7 |

All seven channels use `/usr/libexec/cc-set-fan-duty.sh <idx> {duty}` for
PWM writes. The wrapper enforces a 5% BMC-validation floor (see script
header for rationale).

**⚠️ Iteration 2 caveat**: FAN6 (chipset) and FAN7 (VRM) cool critical
board components. The curves recommended in `silent-curves-reference.md`
have generous floors (20% / 30%) and aggressive ramp-up thresholds. Don't
lower them without understanding your VRM thermal margin under sustained
load. The bridge's `ExecStop` reverts these to BMC default mode if
coolercontrold stops/crashes — so the BMC's own thermal protection
remains the failsafe.

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

## All board fans now controllable

Iteration 1 had FAN6 (chipset) and FAN7 (VRM) on BMC default curves
because they're tiny high-RPM screamers cooling critical components,
and we wanted to validate the bridge architecture on case fans first.
Iteration 2 (this version) brings them into CoolerControl with
conservative floors and aggressive ramp-up — primary user-facing
benefit is noise reduction at idle/light load.

The wrapper validates `fan_idx ∈ 1..7`. There are no BMC FAN8+ slots
exposed by this board; if upstream coolercontrold ever asks for a
duty on an out-of-range index, the wrapper rejects with exit 64.
