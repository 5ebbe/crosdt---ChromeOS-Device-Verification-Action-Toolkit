#!/bin/bash

# verify_sn.sh v.1.0
# Verifies serialNumbers from a GSheet against the domain and writes the
# following sheets back into the same GSheet:
#   all_sn        -> full validity results for every serial checked
#   verified_sn   -> serials with an exact match (serialNumber + exactMatchDeviceIds)
#   mismatched_sn -> serials with no exact match (serialNumber)
#
# Design:
#   Step 1 runs the validity check ONCE (the slow part) and writes the full
#   result to a LOCAL csv. That local csv is then uploaded to the all_sn sheet
#   and split locally with awk into the two result sheets. All filtering is
#   done locally; GAM only performs the validity check and plain sheet uploads.
#
# Requires GAM7: https://github.com/GAM-team/GAM
# By Sebastian Bergstroem, https://github.com/5ebbe

. config.cfg # Import global configuration from config.cfg

if [ "$#" -gt 0 ]; then
    echo "Error: This script does not accept any arguments. Please run the script without any arguments."
    exit 1
fi

# Define logfile name.
LOGFILE="$LOGDIR"/"$DATE"_"$TIME"_verify_sn.log

## ACTUAL SCRIPT ##

# Writes gam version info to the logfile
$GAMCMD version >> "$LOGFILE"
echo "" >> "$LOGFILE"

echo "verify_sn.sh v.0.3 by Sebastian Bergström, https://github.com/5ebbe"
echo "Verifies serialNumbers against the domain and writes all_sn, verified_sn + mismatched_sn back to the GSheet."
echo
echo "Please see readme.txt for documentation."
echo

# Local working files.
RAW=$(mktemp)          # full validity results
MATCHED=$(mktemp)      # serialNumber + exactMatchDeviceIds for exact matches
MISMATCHED=$(mktemp)   # serialNumber for non-matches
INPUTSNS=$(mktemp)     # deduplicated input serials, fed to the validity check

# Helper: upload a local CSV into a named sheet (tab), creating the tab if it
# doesn't exist yet and replacing its contents if it does. GAM has no single
# create-or-update verb: "gsheet" only updates an existing tab, "addsheet" only
# adds a new one. So we try gsheet first; if that fails (tab missing), we fall
# back to addsheet. Args: $1 = local csv path, $2 = target sheet/tab name.
upsert_sheet() {
    local localcsv="$1"
    local sheetname="$2"
    # Create-or-replace with a GUARANTEED full data replacement:
    #   gsheet "<name>" clearfilter  -> updates an existing tab; clearfilter makes
    #     the uploaded CSV COMPLETELY replace the existing data (per GAM docs, with
    #     clearfilter the uploaded data fully replaces what was there, so no stale
    #     rows survive from a previous longer run).
    # If the tab does not exist yet, gsheet updates nothing and returns success,
    # so we detect that case by checking sheet existence first and use addsheet.
    if sheet_exists "$sheetname"; then
        $GAMCMD user "$FILEOWNER" update drivefile "$FILEID" \
            localfile "$localcsv" retainname gsheet "$sheetname" clearfilter 2>> "$LOGFILE"
    else
        $GAMCMD user "$FILEOWNER" update drivefile "$FILEID" \
            localfile "$localcsv" retainname addsheet "$sheetname" 2>> "$LOGFILE"
    fi
}

# Return 0 if a sheet/tab with the given name exists in $FILEID, else 1.
# GAM's `info sheet ... fields sheets` lists each tab with a "title:" line; we
# match the exact tab name after that label, tolerating leading whitespace.
sheet_exists() {
    local name="$1"
    $GAMCMD user "$FILEOWNER" info sheet "$FILEID" fields sheets 2>> "$LOGFILE" \
        | grep -Eq "title:[[:space:]]*${name}[[:space:]]*$"
}

# 0. Read the input serials from CHECK_SN and de-duplicate them FIRST, so the
#    same serial is never checked (or written to the output sheets) twice.
#    Duplicates in the input are reported but harmless once removed.
echo "Step 1/5: Reading and de-duplicating input serials from '$CHECK_SN'..."
SHEETIN=$(mktemp)
$GAMCMD user "$FILEOWNER" get drivefile "$FILEID" \
    csvsheet "$CHECK_SN" targetname - > "$SHEETIN" 2>> "$LOGFILE"

if [ ! -s "$SHEETIN" ] || ! head -1 "$SHEETIN" | grep -qi "serialNumber"; then
    echo "ERROR: Could not read '$CHECK_SN' or it lacks a serialNumber column."
    echo "       Ensure the input tab exists with 'serialNumber' in row 1."
    rm -f "$RAW" "$MATCHED" "$MISMATCHED" "$INPUTSNS" "$SHEETIN"
    exit 1
fi

# Find the serialNumber column, extract it, trim whitespace/CR, drop blanks.
SNIN_COL=$(head -1 "$SHEETIN" | tr -d '\r' | tr ',' '\n' | grep -nxi "serialNumber" | head -1 | cut -d: -f1)
RAW_SNS=$(mktemp)
tr -d '\r' < "$SHEETIN" \
    | awk -F',' -v c="$SNIN_COL" 'NR>1 {v=$c; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v!="") print v}' > "$RAW_SNS"

TOTAL_IN=$(grep -c . "$RAW_SNS")
# De-duplicate (case-insensitive, since serials may differ only in case).
echo "serialNumber" > "$INPUTSNS"
awk '{ key=toupper($0); if(!seen[key]++) print }' "$RAW_SNS" >> "$INPUTSNS"
UNIQUE_IN=$(( $(wc -l < "$INPUTSNS") - 1 ))
DUP_IN=$(( TOTAL_IN - UNIQUE_IN ))
[ "$DUP_IN" -lt 0 ] && DUP_IN=0
rm -f "$SHEETIN" "$RAW_SNS"

echo "         Input serials: $TOTAL_IN total, $UNIQUE_IN unique, $DUP_IN duplicate(s) removed."

# 2. Run the validity check ONCE on the DEDUPLICATED serials. Writes the FULL
#    result set to a LOCAL csv. This is the slow step (one API call per serial).
echo "Step 2/5: Running validity check on unique serials (this is the slow part)..."
$GAMCMD config num_threads 5 show_gettings false \
    csv_input_row_drop_filter "serialNumber:regex:^$" \
    redirect csv "$RAW" multiprocess \
    redirect stderr "$LOGFILE" multiprocess \
    csv "$INPUTSNS" \
    gam print chromesnvalidity cros_sn "~serialNumber"
STEP1_RC=$?

# Guard: abort if the check failed or produced no usable output.
if [ "$STEP1_RC" -ne 0 ]; then
    echo "ERROR: Validity check exited with code $STEP1_RC. Check $LOGFILE."
    rm -f "$RAW" "$MATCHED" "$MISMATCHED" "$INPUTSNS"
    exit 1
fi
if [ ! -s "$RAW" ] || ! head -1 "$RAW" | grep -q "exactMatches"; then
    echo "ERROR: Validity check produced no usable output (missing exactMatches header)."
    echo "       Check $LOGFILE for details. No sheets were written."
    rm -f "$RAW" "$MATCHED" "$MISMATCHED" "$INPUTSNS"
    exit 1
fi
if [ "$(wc -l < "$RAW")" -lt 2 ]; then
    echo "ERROR: Validity check returned a header but no data rows. Check $LOGFILE."
    rm -f "$RAW" "$MATCHED" "$MISMATCHED" "$INPUTSNS"
    exit 1
fi
echo "         OK: $(( $(wc -l < "$RAW") - 1 )) unique serials processed."

# 3. Upload the full result to the all_sn sheet (create or replace).
echo "Step 3/5: Uploading full results to all_sn..."
upsert_sheet "$RAW" "all_sn"

# 4. Split the local results with awk into matched / mismatched CSVs.
#    Column positions are read from the header so order doesn't matter.
echo "Step 4/5: Splitting results locally..."
SN_COL=$(head -1 "$RAW" | tr ',' '\n' | grep -nx "serialNumber" | cut -d: -f1)
EM_COL=$(head -1 "$RAW" | tr ',' '\n' | grep -nx "exactMatches" | cut -d: -f1)
DID_COL=$(head -1 "$RAW" | tr ',' '\n' | grep -nx "exactMatchDeviceIds" | cut -d: -f1)

# verified_sn: serialNumber + exactMatchDeviceIds where exactMatches >= 1
echo "serialNumber,exactMatchDeviceIds" > "$MATCHED"
# mismatched_sn: serialNumber where exactMatches == 0
echo "serialNumber" > "$MISMATCHED"

awk -F',' -v sn="$SN_COL" -v em="$EM_COL" -v did="$DID_COL" \
    -v matched="$MATCHED" -v mismatched="$MISMATCHED" '
    NR>1 {
        if ($em+0 >= 1) print $sn "," $did >> matched;
        else print $sn >> mismatched;
    }' "$RAW"

# 5. Upload the two split sheets (create or replace).
echo "Step 5/5: Uploading verified_sn and mismatched_sn..."
upsert_sheet "$MATCHED" "verified_sn"
upsert_sheet "$MISMATCHED" "mismatched_sn"

# Summary.
echo
echo "Done. Input: $TOTAL_IN serials ($DUP_IN duplicate(s) removed, $UNIQUE_IN unique checked)."

# Clean up local working files.
rm -f "$RAW" "$MATCHED" "$MISMATCHED" "$INPUTSNS"

echo
echo "-- End of script --"
wait
