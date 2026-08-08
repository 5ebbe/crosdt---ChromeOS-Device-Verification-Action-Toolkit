# ChromeOS Device Verification & Action Toolkit
# 2026-08-08, v.1.0 by Sebastian Bergstroem, https://github.com/5ebbe

Two Bash scripts that use [GAM7](https://github.com/GAM-team/GAM) to manage the
lifecycle of ChromeOS devices in a Google Workspace domain, driven entirely by a
Google Sheet:

- **`verify_sn.sh`** — takes a list of serial numbers, checks each one against
  the domain, and sorts them into "found" and "not found".
- **`action_cros.sh`** — takes the verified devices and disables, re-enables, or
  deprovisions them, optionally moves them to another OU, and writes a full
  before/after report.

Both scripts read all of their settings from a single **`config.cfg`** file, and
both read from and write to **one Google Sheet file** whose ID you put in that
config. You never edit the scripts to run a job — you edit the sheet and the
config.

---

## 1. What you need before starting

- GAM7 installed and authorised for your domain (the scripts call the `gam`
  executable at the path you set in `config.cfg`).
- An admin account that owns (or can write to) the Google Sheet you will use.
- The three files in one directory: `verify_sn.sh`, `action_cros.sh`,
  `config.cfg`.

---

## 2. First-time setup: create the Google Sheet

The recommended workflow is to start each job from a **fresh, empty Google
Sheet** so nothing from a previous run lingers.

1. Create a brand-new Google Sheet in the account named by `FILEOWNER`.
2. Copy its **file ID** from the URL. The ID is the long string between
   `/d/` and `/edit`:
   `https://docs.google.com/spreadsheets/d/`**`THIS_IS_THE_FILE_ID`**`/edit`
3. Paste that ID into `config.cfg` as the value of `FILEID`.
4. Rename the first tab to match your `CHECK_SN` config value — by default that
   is **`CHECK`**.
5. In that tab, put the header **`serialNumber`** in cell **A1**.
6. List every serial number you want to process in column A, one per row,
   starting at **A2**.

That is the only sheet content you create by hand. Everything else is generated
by the scripts.

```
        A
1   serialNumber
2   5CD634DMTZ
3   5CD634DN25
4   5CD634DMXT
...
```

Duplicates, mixed upper/lowercase, and stray spaces are fine — the scripts clean
and de-duplicate the input for you (see §6).

---

## 3. The config file (`config.cfg`)

Every setting the scripts use lives here. The most important ones:

| Variable | What it does |
|---|---|
| `GAM` | Absolute path to your GAM executable. |
| `MAINDIR` | Working directory for the scripts; logs are written to `MAINDIR/log`. |
| `FILEOWNER` | The account that owns / can write the Google Sheet. |
| `FILEID` | The file ID of the Google Sheet (from §2). **This is how the scripts know which sheet to use.** |
| `DOMAIN` | Only needed if your GAM manages multiple domains. When set, `select <domain>` is added to every GAM command. Leave empty otherwise. |
| `CHECK_SN` | The name of the **input tab** holding your serials. Must match the tab you named in §2 (default `CHECK`). |

### Action settings (used only by `action_cros.sh`)

| Variable | What it does |
|---|---|
| `ACTION` | `disable`, `enable`, `deprovision`, or `none`. Determines what happens to each verified device. `none` does nothing to devices (dry-run friendly). |
| `DEPROV_METHOD` | The deprovision reason, used **only** when `ACTION="deprovision"`. One of `retiring_device`, `different_model_replace`, `same_model_replace`, `upgrade_transfer`. |
| `MOVE_AFTER` | `true` or `false`. If true, devices are moved to `MOVE_OU` after the action. |
| `MOVE_OU` | Destination OU path for the move (used only when `MOVE_AFTER="true"`). |

The remaining variables (`START`, `DATE`, `TIME`, `GAMCMD`, `LOGDIR`, etc.) are
set automatically for logging and should be left alone. The `GAMCMD` block at
the bottom of the file must stay at the end.

---

## 4. Step one: `verify_sn.sh`

**Purpose:** confirm which of your submitted serial numbers actually exist as
devices in the domain.

Run it:

```bash
./verify_sn.sh
```

What it does, in order:

1. **Reads and de-duplicates the input.** It reads column `serialNumber` from
   the `CHECK` tab, trims whitespace, removes duplicates (case-insensitive), and
   reports how many were submitted, how many were unique, and how many
   duplicates it dropped.
2. **Checks each unique serial against the domain.** This is the slow step (one
   lookup per serial). Each serial either resolves to exactly one device (a
   match) or to none (a mismatch).
3. **Writes `all_sn`** — the full raw result of the validity check.
4. **Splits the results** locally into matches and non-matches.
5. **Writes `verified_sn` and `mismatched_sn`** (see §5).

At the end it prints a summary like:

```
Done. Input: 1479 serials (187 duplicate(s) removed, 1292 unique checked).
```

---

## 5. The sheets the scripts create

You create only the `CHECK` tab. The scripts create and maintain the rest **as
additional tabs inside the same Google Sheet file**. Each run replaces the
contents of these tabs (it does not append), so the sheet always reflects the
most recent run.

| Tab | Created by | Contents |
|---|---|---|
| `CHECK` | **you** | Your input: header `serialNumber` in A1, serials below. |
| `all_sn` | `verify_sn.sh` | The complete validity-check result for every unique serial, including how many devices each matched. |
| `verified_sn` | `verify_sn.sh` | The serials that matched exactly one device, plus that device's ID (`exactMatchDeviceIds`). **This is the input to `action_cros.sh`.** |
| `mismatched_sn` | `verify_sn.sh` | The serials that matched **no** device. These are your "not found" serials. |
| `final_check` | `action_cros.sh` | One row per device with its status and OU **before and after** the action. This is the per-device audit trail. |
| `unresolved` | `action_cros.sh` | Only created if some device IDs from `verified_sn` no longer resolve to a live device. Lists exactly which IDs, so you can inspect them. |

> **Note on row counts:** if you inspect the sheet you may see a tab reporting a
> row count like 1000. That is the Google Sheets grid size, not the number of
> data rows. The scripts always count actual non-empty rows, so the reported
> figures are accurate regardless of grid padding.

---

## 6. Step two: `action_cros.sh`

**Purpose:** apply the configured `ACTION` to every device in `verified_sn`,
optionally move them, and produce a full accounting.

Run it:

```bash
./action_cros.sh
```

### Safety first

Before doing anything, the script prints a **review block** showing the domain,
file ID, source sheet, the action, and the move destination. You must then
confirm at a prompt:

- For most actions, type `go` to proceed.
- For **deprovision** (which is irreversible), you must first type `DEPROVISION`
  in capitals, then `go`. A red warning is shown.

Pressing `Ctrl+C` at any prompt aborts safely with nothing changed.

### What it does, in order

1. **Reads device IDs from `verified_sn`** (no re-lookup by serial — it uses the
   device IDs verify already found, which is fast). It also reads the original
   `CHECK` tab to recover the raw input totals, and captures each device's
   **before** state (status + OU).
2. **Applies the action** to each device, skipping any device already in the
   target state (e.g. a device that is already deprovisioned is not
   deprovisioned again).
3. **Moves devices** to `MOVE_OU` in one fast batch if `MOVE_AFTER="true"`,
   skipping any device already in that OU.
4. **Captures the after state**, joins it with the before state, and writes the
   `final_check` tab.
5. **Generates a timestamped Google Doc report** (a new doc each run) in the
   owner's Drive, containing the summary, the reconciliation, and the mismatched
   serials. The link is printed at the end of the run.

---

## 7. How everything is accounted for

The whole point of the toolkit is that **every serial you submitted is
accounted for** at the end — nothing silently disappears. Both the on-screen
output and the Google Doc report include a **reconciliation** that traces the
numbers from the raw input all the way down to the devices actually acted on.

The reconciliation reads, top to bottom:

**Input serials submitted** — the raw count from your `CHECK` tab, before any
cleaning. This matches what `verify_sn.sh` reported.
  - **Duplicate serials** — how many were duplicates (removed during verify).
  - **Unique serials checked** — what remained after de-duplication.

**Serials in output sheets** — matched + mismatched.
  - **Matched serials** — resolved to a device (from `verified_sn`).
  - **Mismatched serials** — resolved to no device (from `mismatched_sn`).

**Duplicates in output sheets** — a safety check in case the sheets were
hand-edited:
  - **Duplicate serials** — repeated serials within `verified_sn`.
  - **Duplicate device IDs** — the same device listed more than once.

**Of the matched entries:**
  - **Unique devices** — distinct devices asked about.
  - **Resolved to a device** — how many were still live in the domain.
  - **Did not resolve** — device IDs that no longer exist (written to the
    `unresolved` tab for inspection).

Because these figures are derived independently — the input totals from `CHECK`,
the matched/mismatched split from the output tabs, and the resolved counts from
the live domain query — they let you confirm the books balance. For example, if
you submit 1479 serials and 187 are duplicates, you expect 1292 unique; if 1194
of those match and 98 do not, 1194 + 98 = 1292, and every serial is explained.

### Why the two scripts can report slightly different bases

`verify_sn.sh` sees the **raw input** (including duplicates). `action_cros.sh`
reads the **de-duplicated output sheets**, but also reads the original `CHECK`
tab so it can report the same raw totals verify did. If you ever run
`action_cros.sh` against a file whose `CHECK` tab has been removed, it simply
omits the raw-input section and starts its reconciliation at "Serials in output
sheets" — it still runs correctly.

---

## 8. Recommended workflow summary

1. Create a fresh Google Sheet; put its ID in `config.cfg` (`FILEID`).
2. Update GAM, MAINDIR etc. within `config.cfg`
2. Name the first tab `CHECK` (or whatever `CHECK_SN` says); header
   `serialNumber` in A1; serials below.
3. Set `ACTION`, `DEPROV_METHOD`, `MOVE_AFTER`, `MOVE_OU` in `config.cfg`.
4. Run `./verify_sn.sh`. Check `verified_sn` and `mismatched_sn`.
5. Do a dry run: set `ACTION="none"`, `MOVE_AFTER="false"`, run
   `./action_cros.sh`, and review the reconciliation and `final_check`.
6. When satisfied, set the real `ACTION` (and `MOVE_AFTER`), run
   `./action_cros.sh`, confirm at the prompt, and read the generated report.

---

## 9. Where things are written

- **Google Sheet tabs:** `all_sn`, `verified_sn`, `mismatched_sn`,
  `final_check`, `unresolved` — all inside the file named by `FILEID`.
- **Report:** a new Google Doc per run, in the `FILEOWNER` account's Drive; the
  link is printed at the end of `action_cros.sh`.
- **Logs:** `MAINDIR/log/`, one timestamped log file per run.
