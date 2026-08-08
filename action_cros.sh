#!/bin/bash

# action_cros.sh v.1.0
# Reads verified_sn (serialNumber + exactMatchDeviceIds) from the GSheet and,
# per config, disables or deprovisions each device, then optionally moves every
# device in the sheet to a target OU.
#
# Skip logic: a device already in the target state (disabled / deprovisioned)
# is NOT re-actioned. The move, when enabled, applies to EVERY device in the
# sheet regardless of whether its action was skipped.
#
# Requires GAM7: https://github.com/GAM-team/GAM
# By Sebastian Bergstroem, https://github.com/5ebbe

. config.cfg # Import global configuration from config.cfg

if [ "$#" -gt 0 ]; then
    echo "Error: This script does not accept any arguments. Please run without arguments."
    exit 1
fi

LOGFILE="$LOGDIR"/"$DATE"_"$TIME"_action_cros.log

# ---------------------------------------------------------------------------
# Sheet write helpers (create-or-replace with guaranteed full data replacement)
# ---------------------------------------------------------------------------
# Return 0 if a sheet/tab with the given name exists in $FILEID, else 1.
sheet_exists() {
    local name="$1"
    $GAMCMD user "$FILEOWNER" info sheet "$FILEID" fields sheets 2>> "$LOGFILE" \
        | grep -Eq "title:[[:space:]]*${name}[[:space:]]*$"
}

# Create-or-replace a named tab from a local CSV. If the tab exists, gsheet +
# clearfilter fully replaces its data (no stale rows survive from a previous,
# longer run). If it does not exist, addsheet creates it.
upsert_sheet() {
    local localcsv="$1"
    local sheetname="$2"
    if sheet_exists "$sheetname"; then
        $GAMCMD user "$FILEOWNER" update drivefile "$FILEID" \
            localfile "$localcsv" retainname gsheet "$sheetname" clearfilter 2>> "$LOGFILE"
    else
        $GAMCMD user "$FILEOWNER" update drivefile "$FILEID" \
            localfile "$localcsv" retainname addsheet "$sheetname" 2>> "$LOGFILE"
    fi
}


# ---------------------------------------------------------------------------
# Validate config
# ---------------------------------------------------------------------------
case "$ACTION" in
    disable|enable|deprovision|none) ;;
    *) echo "ERROR: ACTION must be disable, enable, deprovision, or none (got: '$ACTION'). Check config.cfg."; exit 1 ;;
esac

# Map the short DEPROV_METHOD name to the GAM7 CrOSAction keyword.
DEPROV_ACTION=""
if [ "$ACTION" = "deprovision" ]; then
    case "$DEPROV_METHOD" in
        retiring_device)         DEPROV_ACTION="deprovision_retiring_device" ;;
        different_model_replace) DEPROV_ACTION="deprovision_different_model_replace" ;;
        same_model_replace)      DEPROV_ACTION="deprovision_same_model_replace" ;;
        upgrade_transfer)        DEPROV_ACTION="deprovision_upgrade_transfer" ;;
        *) echo "ERROR: DEPROV_METHOD must be one of: retiring_device, different_model_replace, same_model_replace, upgrade_transfer (got: '$DEPROV_METHOD'). Check config.cfg."; exit 1 ;;
    esac
fi

if [ "$MOVE_AFTER" = "true" ] && [ -z "$MOVE_OU" ]; then
    echo "ERROR: MOVE_AFTER is true but MOVE_OU is empty. Set MOVE_OU in config.cfg."
    exit 1
fi

# Colour codes for the terminal (red for the irreversible warning).
RED=$'\033[1;31m'
RESET=$'\033[0m'

echo "action_cros.sh v.1.0 By Sebastian Bergstroem, https://github.com/5ebbe"
echo
echo "Please see readme.txt for documentation."

# ---------------------------------------------------------------------------
# PRE-FLIGHT: show exactly what will happen, using config values only, and
# require a typed 'go' BEFORE any GAM processing or sheet read is done. The
# script does not depend on verify_sn.sh having run; it only needs verified_sn
# to contain the correct data.
# ---------------------------------------------------------------------------
echo "=============================================================="
echo " REVIEW BEFORE PROCEEDING"
echo "=============================================================="
echo " Domain           : ${DOMAIN:-(none / default)}"
echo " GSheet file ID   : $FILEID"
echo " Source sheet     : verified_sn"
case "$ACTION" in
    disable)
        echo " Action           : DISABLE (reversible)"
        echo "                    Devices already disabled will be skipped." ;;
    enable)
        echo " Action           : ENABLE / re-enable"
        echo "                    Only currently disabled devices will be enabled." ;;
    deprovision)
        echo " Action           : DEPROVISION  ->  $DEPROV_ACTION"
        echo "                    Devices already deprovisioned will be skipped." ;;
    none)
        echo " Action           : NONE (no disable/enable/deprovision)" ;;
esac
if [ "$MOVE_AFTER" = "true" ]; then
    echo " Move after       : YES  ->  $MOVE_OU"
    echo "                    Devices already in that OU will be skipped."
else
    echo " Move after       : NO move"
fi
echo "=============================================================="
echo

# Extra, prominent warning for the irreversible deprovision action.
if [ "$ACTION" = "deprovision" ]; then
    echo "${RED}*** WARNING: DEPROVISION IS IRREVERSIBLE. ***${RESET}"
    echo "${RED}Each affected device must be physically wiped and re-enrolled${RESET}"
    echo "${RED}to be managed by the domain again.${RESET}"
    echo "${RED}Deprovision method: $DEPROV_ACTION${RESET}"
    echo
fi

echo "If any of the above is wrong, press Ctrl+C now and fix config.cfg."
echo

# Prompts read from /dev/tty so they work regardless of stdin state.
if [ "$ACTION" = "deprovision" ]; then
    printf "%sType DEPROVISION followed by Enter to continue, or Ctrl+C to abort: %s" "$RED" "$RESET"
    read -r CONFIRM_D < /dev/tty
    if [ "$CONFIRM_D" != "DEPROVISION" ]; then
        echo "Aborted. No changes made."
        exit 1
    fi
fi

printf "To proceed, type go followed by Enter. To abort, press Ctrl+C: "
read -r CONFIRM_GO < /dev/tty
if [ "$CONFIRM_GO" != "go" ] && [ "$CONFIRM_GO" != "GO" ]; then
    echo "Aborted. No changes made."
    exit 1
fi
echo

# ---------------------------------------------------------------------------
# Local working files
# ---------------------------------------------------------------------------
IDFILE=$(mktemp)   # single-column deviceId CSV, read straight from verified_sn
BEFORE=$(mktemp)   # deviceId,serialNumber,status,orgUnitPath BEFORE processing
AFTER=$(mktemp)    # same, re-fetched AFTER processing
REPORT=$(mktemp)   # local HTML for the GDoc report

# ---------------------------------------------------------------------------
# 1. Get device IDs directly from verified_sn (the exactMatchDeviceIds column
#    that verify_sn.sh already resolved), then fetch BEFORE state by device ID
#    in a single pass. No per-serial query/search is performed.
# ---------------------------------------------------------------------------
echo "Step 1/5: Reading device IDs from verified_sn and capturing BEFORE state..."

# Read the sheet locally to extract exactMatchDeviceIds. get drivefile csvsheet
# dumps the tab to stdout as CSV without any device lookups.
SHEETCSV=$(mktemp)
$GAMCMD user "$FILEOWNER" get drivefile "$FILEID" \
    csvsheet "verified_sn" targetname - > "$SHEETCSV" 2>> "$LOGFILE"

if [ ! -s "$SHEETCSV" ] || ! head -1 "$SHEETCSV" | grep -q "exactMatchDeviceIds"; then
    echo "ERROR: Could not read verified_sn, or it lacks an exactMatchDeviceIds column."
    echo "       Run verify_sn.sh against file $FILEID first (it produces that column)."
    rm -f "$IDFILE" "$BEFORE" "$AFTER" "$REPORT" "$SHEETCSV"
    exit 1
fi

# Extract the deviceId column into an ID file with a 'deviceId' header, for use
# as a croscsvfile selector. Also capture the raw serialNumber list so we can
# report duplicate serials as well as duplicate device IDs. Strip carriage
# returns (sheet CSV may have CRLF) and surrounding whitespace. Skip blanks.
DIDCOL=$(head -1 "$SHEETCSV" | tr -d '\r' | tr ',' '\n' | grep -nx "exactMatchDeviceIds" | cut -d: -f1)
SNCOL=$(head -1 "$SHEETCSV"  | tr -d '\r' | tr ',' '\n' | grep -nxi "serialNumber"        | head -1 | cut -d: -f1)

RAW_SN_LIST=$(mktemp)   # every serial as listed in the sheet (with duplicates)
echo "deviceId" > "$IDFILE"
tr -d '\r' < "$SHEETCSV" \
    | awk -F',' -v c="$DIDCOL" 'NR>1 {
        v=$c
        gsub(/^[ \t]+|[ \t]+$/, "", v)   # trim leading/trailing whitespace
        if (v != "") print v
      }' >> "$IDFILE"
# Raw serial list (may contain duplicates) for reporting.
tr -d '\r' < "$SHEETCSV" \
    | awk -F',' -v c="$SNCOL" 'NR>1 {
        v=$c
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "") print v
      }' > "$RAW_SN_LIST"
rm -f "$SHEETCSV"

# Serial duplicate stats (case-insensitive).
TOTAL_SN=$(grep -c . "$RAW_SN_LIST")
UNIQUE_SN=$(awk '{print toupper($0)}' "$RAW_SN_LIST" | sort -u | grep -c .)
DUPLICATE_SN=$(( TOTAL_SN - UNIQUE_SN ))
[ "$DUPLICATE_SN" -lt 0 ] && DUPLICATE_SN=0

NUM_DEVICES=$(( $(wc -l < "$IDFILE") - 1 ))
[ "$NUM_DEVICES" -lt 0 ] && NUM_DEVICES=0
echo "         $NUM_DEVICES device ID(s) from the sheet."

# Count of verified serials (rows in verified_sn) for the reconciliation later.
# This is the number of matched serials; NUM_DEVICES counts non-blank device IDs.
VERIFIED_ROWS="$NUM_DEVICES"

# Read the ORIGINAL input tab (CHECK_SN) if present, to report the same raw base
# data verify_sn.sh saw: total serials submitted and how many were duplicates.
# This is optional: on a standalone run where only the output sheets exist, the
# input tab may be absent, so we degrade gracefully.
INPUT_TOTAL=0
INPUT_UNIQUE=0
INPUT_DUP=0
INPUT_STATE="missing"   # missing | present
INPUT_TAB="${CHECK_SN:-CHECK}"
INSHEET=$(mktemp)
if $GAMCMD user "$FILEOWNER" get drivefile "$FILEID" \
    csvsheet "$INPUT_TAB" targetname - > "$INSHEET" 2>> "$LOGFILE" \
    && [ -s "$INSHEET" ] && head -1 "$INSHEET" | grep -qi "serialNumber"; then
    ICOL=$(head -1 "$INSHEET" | tr -d '\r' | tr ',' '\n' | grep -nxi "serialNumber" | head -1 | cut -d: -f1)
    IN_SNS=$(mktemp)
    tr -d '\r' < "$INSHEET" \
        | awk -F',' -v c="$ICOL" 'NR>1 {v=$c; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v!="") print v}' > "$IN_SNS"
    INPUT_TOTAL=$(grep -c . "$IN_SNS")
    INPUT_UNIQUE=$(awk '{print toupper($0)}' "$IN_SNS" | sort -u | grep -c .)
    INPUT_DUP=$(( INPUT_TOTAL - INPUT_UNIQUE ))
    [ "$INPUT_DUP" -lt 0 ] && INPUT_DUP=0
    INPUT_STATE="present"
    rm -f "$IN_SNS"
fi
rm -f "$INSHEET"

if [ "$NUM_DEVICES" -eq 0 ]; then
    echo "Nothing to do (no device IDs in verified_sn). Exiting."
    rm -f "$IDFILE" "$BEFORE" "$AFTER" "$REPORT" "$RAW_SN_LIST"
    exit 0
fi

# Fetch BEFORE state for exactly these device IDs, in one pass, keyed by ID.
# The croscsvfile selector precedes 'print cros'. multiprocess is needed on the
# redirect so the parallel per-device output is aggregated into the file.
$GAMCMD redirect csv "$BEFORE" multiprocess \
    croscsvfile "$IDFILE":deviceId print cros \
    fields deviceId,serialNumber,status,orgUnitPath 2>> "$LOGFILE"

BEFORE_ROWS=0
[ -s "$BEFORE" ] && BEFORE_ROWS=$(( $(wc -l < "$BEFORE") - 1 ))
[ "$BEFORE_ROWS" -lt 0 ] && BEFORE_ROWS=0

if [ ! -s "$BEFORE" ] || ! head -1 "$BEFORE" | grep -q "deviceId"; then
    echo "ERROR: Could not fetch device state by deviceId."
    echo "       Header that came back was: $(head -1 "$BEFORE" 2>/dev/null)"
    rm -f "$IDFILE" "$BEFORE" "$AFTER" "$REPORT"
    exit 1
fi
if [ "$BEFORE_ROWS" -eq 0 ]; then
    echo "ERROR: The fetch returned a header but ZERO device rows."
    echo "       $NUM_DEVICES IDs were read from the sheet, but none matched a device."
    echo "       First few device IDs sent to GAM:"
    tail -n +2 "$IDFILE" | head -3 | sed 's/^/         /'
    echo "       Check that the exactMatchDeviceIds column holds clean single device"
    echo "       IDs (one per cell, no quotes/extra text) for file $FILEID."
    rm -f "$IDFILE" "$BEFORE" "$AFTER" "$REPORT"
    exit 1
fi
echo "         Fetched state for $BEFORE_ROWS device(s)."

# Column positions in the BEFORE file.
DID_COL=$(head -1 "$BEFORE" | tr ',' '\n' | grep -nx "deviceId"     | cut -d: -f1)
SN_COL=$(head -1 "$BEFORE"  | tr ',' '\n' | grep -nx "serialNumber" | cut -d: -f1)
ST_COL=$(head -1 "$BEFORE"  | tr ',' '\n' | grep -nx "status"       | cut -d: -f1)
OU_COL=$(head -1 "$BEFORE"  | tr ',' '\n' | grep -nx "orgUnitPath"  | cut -d: -f1)

# ---------------------------------------------------------------------------
# 2. Apply the action per device, skipping devices already in target state.
# ---------------------------------------------------------------------------
ACTED=0
SKIPPED=0
if [ "$ACTION" != "none" ]; then
    # The status that means "action already applied, skip this device".
    #   disable     -> skip if already disabled
    #   enable      -> skip if already enabled (i.e. provisioned/active, not disabled)
    #   deprovision -> skip if already deprovisioned
    case "$ACTION" in
        disable)     DONE_STATE="disabled" ;;
        deprovision) DONE_STATE="deprovisioned" ;;
        enable)      DONE_STATE="enabled" ;;   # handled specially below
    esac

    echo "Step 2/5: Applying '$ACTION'..."

    while IFS=',' read -r LINE_DID LINE_ST; do
        [ -z "$LINE_DID" ] && continue

        CUR=$(printf '%s' "$LINE_ST" | tr '[:upper:]' '[:lower:]')

        # Skip logic:
        #   For enable, a device is "already enabled" if its status is anything
        #   other than 'disabled' (deprovisioned devices can't be re-enabled and
        #   are also skipped). For disable/deprovision, skip if already in state.
        if [ "$ACTION" = "enable" ]; then
            if [ "$CUR" != "disabled" ]; then
                SKIPPED=$((SKIPPED+1))
                continue
            fi
        else
            if [ "$CUR" = "$DONE_STATE" ]; then
                SKIPPED=$((SKIPPED+1))
                continue
            fi
        fi

        case "$ACTION" in
            disable)
                $GAMCMD update cros "$LINE_DID" action disable 2>> "$LOGFILE" ;;
            enable)
                $GAMCMD update cros "$LINE_DID" action reenable 2>> "$LOGFILE" ;;
            deprovision)
                $GAMCMD update cros "$LINE_DID" action "$DEPROV_ACTION" \
                    acknowledge_device_touch_requirement maxtodeprov "$NUM_DEVICES" 2>> "$LOGFILE" ;;
        esac
        ACTED=$((ACTED+1))
    done < <(awk -F',' -v d="$DID_COL" -v s="$ST_COL" 'NR>1 && $d!="" {print $d","$s}' "$BEFORE")

    if [ "$ACTION" = "enable" ]; then
        echo "         Acted on $ACTED, skipped $SKIPPED not-disabled."
    else
        echo "         Acted on $ACTED, skipped $SKIPPED already-$DONE_STATE."
    fi
else
    echo "Step 2/5: ACTION=none, no disable/enable/deprovision performed."
fi

# ---------------------------------------------------------------------------
# 3. Move devices to MOVE_OU (if enabled) in ONE fast batch (quickcrosmove),
#    including only devices whose current OU differs from MOVE_OU.
# ---------------------------------------------------------------------------
MOVED=0
MOVE_SKIPPED=0
if [ "$MOVE_AFTER" = "true" ]; then
    echo "Step 3/5: Moving device(s) to $MOVE_OU (batch; skipping those already there)..."

    # Build an ID file of only the devices that need moving.
    MOVEIDS=$(mktemp)
    echo "deviceId" > "$MOVEIDS"
    while IFS=$'\t' read -r DID CUR_OU; do
        [ -z "$DID" ] && continue
        if [ "$CUR_OU" = "$MOVE_OU" ]; then
            MOVE_SKIPPED=$((MOVE_SKIPPED+1))
        else
            echo "$DID" >> "$MOVEIDS"
            MOVED=$((MOVED+1))
        fi
    done < <(awk -F',' -v d="$DID_COL" -v o="$OU_COL" 'NR>1 && $d!="" {print $d"\t"$o}' "$BEFORE")

    if [ "$MOVED" -gt 0 ]; then
        # One batched move for all devices that need it.
        $GAMCMD update ou "$MOVE_OU" add croscsvfile "$MOVEIDS":deviceId quickcrosmove 2>> "$LOGFILE"
    fi
    rm -f "$MOVEIDS"
    echo "         Moved $MOVED device(s), skipped $MOVE_SKIPPED already in $MOVE_OU."
else
    echo "Step 3/5: MOVE_AFTER is not true, skipping move."
fi

# ---------------------------------------------------------------------------
# 4. Capture AFTER state and build the final_check sheet (before + after).
# ---------------------------------------------------------------------------
echo "Step 4/5: Re-fetching device state and building final_check sheet..."

# Re-read live state for the same device IDs (one pass, by ID).
$GAMCMD redirect csv "$AFTER" multiprocess \
    croscsvfile "$IDFILE":deviceId print cros \
    fields deviceId,serialNumber,status,orgUnitPath 2>> "$LOGFILE"

# Positions in the AFTER file (may differ from BEFORE, so resolve independently).
A_DID=$(head -1 "$AFTER" | tr ',' '\n' | grep -nx "deviceId"    | cut -d: -f1)
A_ST=$(head -1 "$AFTER"  | tr ',' '\n' | grep -nx "status"      | cut -d: -f1)
A_OU=$(head -1 "$AFTER"  | tr ',' '\n' | grep -nx "orgUnitPath" | cut -d: -f1)

# Build final_check.csv joining BEFORE and AFTER by deviceId.
FINALCSV=$(mktemp)
echo "serialNumber,deviceId,status_before,ou_before,status_after,ou_after" > "$FINALCSV"

# Load AFTER into an awk-readable temp keyed by deviceId, then emit joined rows.
awk -F',' \
    -v bdid="$DID_COL" -v bsn="$SN_COL" -v bst="$ST_COL" -v bou="$OU_COL" \
    -v adid="$A_DID"  -v ast="$A_ST"  -v aou="$A_OU" \
    -v afterfile="$AFTER" '
    BEGIN {
        # Read AFTER file into arrays keyed by deviceId.
        while ((getline line < afterfile) > 0) {
            n=split(line, f, ",")
            if (f[adid]=="deviceId") continue   # skip header
            if (f[adid]=="") continue
            aft_st[f[adid]] = f[ast]
            aft_ou[f[adid]] = f[aou]
        }
    }
    NR>1 && $bdid!="" {
        did=$bdid
        print $bsn "," did "," $bst "," $bou "," aft_st[did] "," aft_ou[did]
    }' "$BEFORE" >> "$FINALCSV"

# Upload final_check to the GSheet (create or replace, full data replacement).
upsert_sheet "$FINALCSV" "final_check"
echo "         final_check sheet written."

# Compute status tallies from final_check (columns: sn,did,sb,ob,sa,oa).
# BEFORE_COUNTS / AFTER_COUNTS hold "STATUS<tab>N" lines.
BEFORE_COUNTS=$(tail -n +2 "$FINALCSV" | awk -F',' '$3!=""{c[$3]++} END{for(s in c) print s"\t"c[s]}' | sort)
AFTER_COUNTS=$(tail -n +2 "$FINALCSV"  | awk -F',' '$5!=""{c[$5]++} END{for(s in c) print s"\t"c[s]}' | sort)

# How many sheet device IDs did NOT resolve to a current device in the domain.
# NUM_DEVICES = IDs read from the sheet; BEFORE_ROWS = devices actually returned.
UNRESOLVED=$(( NUM_DEVICES - BEFORE_ROWS ))
[ "$UNRESOLVED" -lt 0 ] && UNRESOLVED=0

# Figure out exactly WHICH sheet IDs did not come back from the fetch, and also
# whether the sheet contained duplicate IDs (a common cause of an apparent gap:
# print cros returns each unique device once, so duplicates inflate NUM_DEVICES
# without adding resolved rows).
UNRESOLVED_FILE=$(mktemp)
SHEET_IDS_SORTED=$(mktemp)
FETCHED_IDS_SORTED=$(mktemp)

# Unique sorted list of IDs we asked for (from the ID file, minus header).
tail -n +2 "$IDFILE" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep . | sort -u > "$SHEET_IDS_SORTED"
# Count of duplicate IDs in the sheet (total asked minus unique).
UNIQUE_SHEET_IDS=$(wc -l < "$SHEET_IDS_SORTED")
DUPLICATE_IDS=$(( NUM_DEVICES - UNIQUE_SHEET_IDS ))
[ "$DUPLICATE_IDS" -lt 0 ] && DUPLICATE_IDS=0

# Unique sorted list of IDs the fetch actually returned (deviceId column of BEFORE).
awk -F',' -v d="$DID_COL" 'NR>1 && $d!="" {print $d}' "$BEFORE" | tr -d '\r' | sort -u > "$FETCHED_IDS_SORTED"

# IDs present in the sheet but absent from the fetch = genuinely unresolved.
echo "deviceId" > "$UNRESOLVED_FILE"
comm -23 "$SHEET_IDS_SORTED" "$FETCHED_IDS_SORTED" >> "$UNRESOLVED_FILE"
UNRESOLVED_TRUE=$(( $(wc -l < "$UNRESOLVED_FILE") - 1 ))
[ "$UNRESOLVED_TRUE" -lt 0 ] && UNRESOLVED_TRUE=0

# Write the unresolved IDs to an 'unresolved' tab so they can be inspected.
if [ "$UNRESOLVED_TRUE" -gt 0 ]; then
    upsert_sheet "$UNRESOLVED_FILE" "unresolved"
fi

# Read the mismatched serials now (needed for the reconciliation below and the
# report later). Distinguish three cases:
#   MISMATCH_STATE=missing  -> the mismatched_sn tab does not exist
#   MISMATCH_STATE=empty    -> tab exists but has no serials (0 mismatches)
#   MISMATCH_STATE=present  -> tab exists with N serials
MISMATCH=$(mktemp)
MISMATCH_STATE="missing"
MISMATCH_COUNT=0
if $GAMCMD user "$FILEOWNER" get drivefile "$FILEID" \
    csvsheet "mismatched_sn" targetname - > "$MISMATCH" 2>> "$LOGFILE"; then
    if [ -s "$MISMATCH" ]; then
        MISMATCH_COUNT=$(tail -n +2 "$MISMATCH" | tr -d '\r' | grep -c '[^[:space:]]')
        if [ "$MISMATCH_COUNT" -gt 0 ]; then
            MISMATCH_STATE="present"
        else
            MISMATCH_STATE="empty"
        fi
    else
        MISMATCH_STATE="empty"
    fi
fi

# Full reconciliation of the numbers, from the top:
#   TOTAL_SN        = every serial in verified_sn, INCLUDING duplicates
#   DUPLICATE_SN    = duplicate serials within verified_sn
#   MISMATCH_COUNT  = serials with no exact match (mismatched_sn)
#   VERIFIED_ROWS   = matched device-ID rows in verified_sn
#   DUPLICATE_IDS   = duplicate device IDs within verified_sn
#   UNIQUE_SHEET_IDS= distinct devices we asked GAM about
#   BEFORE_ROWS     = devices GAM returned
#   UNRESOLVED_TRUE = distinct IDs asked but not returned
# Grand total of serials seen across both tabs (verified incl. dups + mismatched).
GRAND_TOTAL=$(( TOTAL_SN + MISMATCH_COUNT ))

# Keep UNRESOLVED aligned with the true (de-duplicated) figure for the report.
UNRESOLVED="$UNRESOLVED_TRUE"

# Show a full reconciliation on screen, from the raw input total down to resolved.
echo
echo "=============================================================="
echo " RECONCILIATION"
echo "=============================================================="
if [ "$INPUT_STATE" = "present" ]; then
    # Same base data verify_sn.sh reports: raw input total and input duplicates.
    echo "  Input serials submitted   : $INPUT_TOTAL  (original '$INPUT_TAB' tab)"
    echo "    - Duplicate serials      : $INPUT_DUP  (removed at verify)"
    echo "    - Unique serials checked : $INPUT_UNIQUE"
    echo "  --------------------------------------------------------"
fi
if [ "$MISMATCH_STATE" = "missing" ]; then
    echo "  Serials in output sheets  : $TOTAL_SN  (verified_sn; mismatched_sn tab not found)"
    echo "    - Matched serials        : $TOTAL_SN"
    echo "    - Mismatched serials     : unknown (mismatched_sn tab missing)"
else
    echo "  Serials in output sheets  : $GRAND_TOTAL"
    echo "    - Matched serials        : $TOTAL_SN"
    echo "    - Mismatched serials     : $MISMATCH_COUNT"
fi
echo "  --------------------------------------------------------"
echo "  Duplicates in output sheets:"
echo "    - Duplicate serials        : $DUPLICATE_SN"
echo "    - Duplicate device IDs     : $DUPLICATE_IDS"
echo "  --------------------------------------------------------"
echo "  Of the matched entries:"
echo "    - Unique devices           : $UNIQUE_SHEET_IDS"
echo "    - Resolved to a device     : $BEFORE_ROWS"
if [ "$UNRESOLVED_TRUE" -gt 0 ]; then
    echo "    - Did NOT resolve          : $UNRESOLVED_TRUE  (see 'unresolved' tab)"
else
    echo "    - Did NOT resolve          : 0"
fi
echo "=============================================================="
echo
echo "Status counts (see the 'final_check' sheet for per-device details):"
echo "  BEFORE:"
printf '%s\n' "$BEFORE_COUNTS" | while IFS=$'\t' read -r s n; do
    [ -n "$s" ] && printf "    %-16s %s\n" "$s" "$n"
done
echo "  AFTER:"
printf '%s\n' "$AFTER_COUNTS" | while IFS=$'\t' read -r s n; do
    [ -n "$s" ] && printf "    %-16s %s\n" "$s" "$n"
done
echo

# ---------------------------------------------------------------------------
# 5. Generate a timestamped Google Doc report.
# ---------------------------------------------------------------------------
echo "Step 5/5: Generating report GDoc..."

# (Mismatched serials were already read earlier for the reconciliation.)

# Human-readable action description for the report.
case "$ACTION" in
    disable)     ACTION_DESC="Disable (reversible)" ;;
    enable)      ACTION_DESC="Enable / re-enable" ;;
    deprovision) ACTION_DESC="Deprovision ($DEPROV_ACTION) - IRREVERSIBLE" ;;
    none)        ACTION_DESC="None (no disable/enable/deprovision)" ;;
esac
if [ "$MOVE_AFTER" = "true" ]; then
    MOVE_DESC="Yes, to $MOVE_OU"
else
    MOVE_DESC="No move"
fi

# Small helper to HTML-escape a value (&, <, >).
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Build the report as HTML. mimetype gdoc converts HTML to a formatted Google
# Doc, giving real tables and zebra striping (every second row shaded).
{
    cat <<'HTMLHEAD'
<html>
<head>
<style>
  body { font-family: Arial, sans-serif; font-size: 11pt; color: #202124; }
  h1 { font-size: 18pt; margin-bottom: 2pt; }
  h2 { font-size: 13pt; margin-top: 18pt; border-bottom: 1px solid #ccc; padding-bottom: 2pt; }
  table { border-collapse: collapse; width: 100%; margin-top: 6pt; }
  th, td { border: 1px solid #d0d0d0; padding: 4pt 8pt; text-align: left; font-size: 10pt; }
  th { background: #4a4a4a; color: #ffffff; }
  tr:nth-child(even) td { background: #f2f2f2; }
  .summary td:first-child { font-weight: bold; width: 32%; }
  .warn { color: #b00000; font-weight: bold; }
</style>
</head>
<body>
HTMLHEAD

    echo "<h1>ChromeOS Device Action Report</h1>"
    echo "<p><b>Run:</b> $(html_escape "$DATETIME")</p>"

    # Summary table.
    echo "<h2>Summary</h2>"
    echo "<table class=\"summary\">"
    echo "<tr><td>Domain</td><td>$(html_escape "${DOMAIN:-(none / default)}")</td></tr>"
    echo "<tr><td>GSheet file ID</td><td>$(html_escape "$FILEID")</td></tr>"
    echo "<tr><td>Action</td><td>$(html_escape "$ACTION_DESC")</td></tr>"
    echo "<tr><td>Devices in scope</td><td>$NUM_DEVICES (device IDs from verified_sn)</td></tr>"
    echo "<tr><td>Resolved to a current device</td><td>$BEFORE_ROWS</td></tr>"
    if [ "$UNRESOLVED" -gt 0 ]; then
        echo "<tr><td>Did not resolve</td><td>$UNRESOLVED (see the 'unresolved' tab in the source spreadsheet)</td></tr>"
    fi
    if [ "$ACTION" != "none" ]; then
        echo "<tr><td>Acted on</td><td>$ACTED</td></tr>"
        echo "<tr><td>Skipped (already in target state)</td><td>$SKIPPED</td></tr>"
    fi
    echo "<tr><td>Move</td><td>$(html_escape "$MOVE_DESC")</td></tr>"
    if [ "$MOVE_AFTER" = "true" ]; then
        echo "<tr><td>Moved</td><td>$MOVED</td></tr>"
        echo "<tr><td>Move skipped (already in OU)</td><td>$MOVE_SKIPPED</td></tr>"
    fi
    echo "</table>"

    # Reconciliation table: accounts for every serial from the top.
    echo "<h2>Reconciliation</h2>"
    echo "<table class=\"summary\">"
    if [ "$INPUT_STATE" = "present" ]; then
        echo "<tr><td>Input serials submitted</td><td>$INPUT_TOTAL (original '$(html_escape "$INPUT_TAB")' tab)</td></tr>"
        echo "<tr><td>&nbsp;&nbsp;Duplicate serials (removed at verify)</td><td>$INPUT_DUP</td></tr>"
        echo "<tr><td>&nbsp;&nbsp;Unique serials checked</td><td>$INPUT_UNIQUE</td></tr>"
    fi
    if [ "$MISMATCH_STATE" = "missing" ]; then
        echo "<tr><td>Serials in output sheets</td><td>$TOTAL_SN (verified_sn; mismatched_sn tab not found)</td></tr>"
        echo "<tr><td>&nbsp;&nbsp;Matched serials</td><td>$TOTAL_SN</td></tr>"
        echo "<tr><td>&nbsp;&nbsp;Mismatched serials</td><td>unknown (mismatched_sn tab missing)</td></tr>"
    else
        echo "<tr><td>Serials in output sheets</td><td>$GRAND_TOTAL</td></tr>"
        echo "<tr><td>&nbsp;&nbsp;Matched serials</td><td>$TOTAL_SN</td></tr>"
        echo "<tr><td>&nbsp;&nbsp;Mismatched serials</td><td>$MISMATCH_COUNT</td></tr>"
    fi
    echo "<tr><td>Duplicate serials (output sheets)</td><td>$DUPLICATE_SN</td></tr>"
    echo "<tr><td>Duplicate device IDs (output sheets)</td><td>$DUPLICATE_IDS</td></tr>"
    echo "<tr><td>Unique devices</td><td>$UNIQUE_SHEET_IDS</td></tr>"
    echo "<tr><td>&nbsp;&nbsp;Resolved to a current device</td><td>$BEFORE_ROWS</td></tr>"
    if [ "$UNRESOLVED" -gt 0 ]; then
        echo "<tr><td>&nbsp;&nbsp;Did not resolve</td><td>$UNRESOLVED (see the 'unresolved' tab)</td></tr>"
    else
        echo "<tr><td>&nbsp;&nbsp;Did not resolve</td><td>0</td></tr>"
    fi
    echo "</table>"

    # Status count summary (before -> after).
    echo "<h2>Status counts</h2>"
    echo "<p>Totals by device status. See the <b>final_check</b> sheet in the source"
    echo "spreadsheet for per-device details (serial, deviceId, status, OU).</p>"
    echo "<table>"
    echo "<tr><th>Status</th><th>Before</th><th>After</th></tr>"
    # Union of statuses seen in before and after, with counts for each.
    {
        printf '%s\n' "$BEFORE_COUNTS" | awk -F'\t' 'NF{print $1}'
        printf '%s\n' "$AFTER_COUNTS"  | awk -F'\t' 'NF{print $1}'
    } | sort -u | while IFS= read -r st; do
        [ -z "$st" ] && continue
        bn=$(printf '%s\n' "$BEFORE_COUNTS" | awk -F'\t' -v s="$st" '$1==s{print $2}')
        an=$(printf '%s\n' "$AFTER_COUNTS"  | awk -F'\t' -v s="$st" '$1==s{print $2}')
        echo "<tr><td>$(html_escape "$st")</td><td>${bn:-0}</td><td>${an:-0}</td></tr>"
    done
    echo "<tr><td><b>Total (resolved)</b></td><td><b>$BEFORE_ROWS</b></td><td><b>$BEFORE_ROWS</b></td></tr>"
    echo "</table>"

    # Mismatched serials section, with clear wording per state.
    case "$MISMATCH_STATE" in
        present)
            echo "<h2>Mismatched serial numbers ($MISMATCH_COUNT)</h2>"
            echo "<table>"
            echo "<tr><th>serialNumber</th></tr>"
            tail -n +2 "$MISMATCH" | tr -d '\r' | while IFS= read -r line; do
                # Skip blank / whitespace-only lines.
                case "$line" in ''|*[!\ ]*) ;; esac
                [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
                echo "<tr><td>$(html_escape "$line")</td></tr>"
            done
            echo "</table>"
            ;;
        empty)
            echo "<h2>Mismatched serial numbers (0)</h2>"
            echo "<p>The mismatched_sn sheet was read and contained no serials.</p>"
            ;;
        missing)
            echo "<h2>Mismatched serial numbers (unknown)</h2>"
            echo "<p class=\"warn\">The mismatched_sn sheet was not found in this file, so mismatches could not be determined. Run verify_sn.sh against this file to generate it.</p>"
            ;;
    esac

    echo "<p style=\"margin-top:18pt; color:#888; font-size:9pt;\">Generated by action_cros.sh</p>"
    echo "</body></html>"
} > "$REPORT"

# Upload as .html so GAM converts it to a formatted Google Doc.
REPORT_HTML="${REPORT}.html"
cp "$REPORT" "$REPORT_HTML"

# Plain-ASCII filename with timestamp (a fancy em dash can cause a Bad Request).
REPORT_NAME="CrOS Action Report - $DATE $TIME"
REPORT_ID=$($GAMCMD user "$FILEOWNER" create drivefile localfile "$REPORT_HTML" \
    mimetype gdoc drivefilename "$REPORT_NAME" returnidonly 2>> "$LOGFILE")

if [ -n "$REPORT_ID" ]; then
    echo "         Report created: \"$REPORT_NAME\""
    echo "         Owner: $FILEOWNER (in that user's My Drive root)"
    echo "         Link : https://docs.google.com/document/d/$REPORT_ID/edit"
else
    echo "         WARNING: Report creation may have failed. Check $LOGFILE."
fi

# Clean up all local working files.
rm -f "$IDFILE" "$BEFORE" "$AFTER" "$REPORT" "$REPORT_HTML" "$FINALCSV" "$MISMATCH" "$UNRESOLVED_FILE" "$SHEET_IDS_SORTED" "$FETCHED_IDS_SORTED" "$RAW_SN_LIST"

echo
echo "-- End of script --"
wait
