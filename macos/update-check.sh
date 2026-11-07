#!/bin/bash
# =====================================================================
# update-check.sh — emails you when a macOS or iOS update is available.
#
# Runs once a day via launchd (~/Library/LaunchAgents/com.jake.update-check.plist).
#   bash ~/Scripts/update-check.sh          normal run
#   bash ~/Scripts/update-check.sh --test   always sends an email showing what it
#                                           sees right now; changes no state
# Files it uses (all in ~/Scripts):
#   update-check.state   what it last told you about (plain text, KEY=VALUE)
#   update-check.log     one line per event, so you can see what it did
# =====================================================================

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ---------- Settings you might change ----------
TO_ADDRESS=""          # empty = use the Gmail address set up in Apple Mail
REMIND_AFTER_DAYS=3    # re-email about a pending Mac update if still not installed after this many days
FAIL_ALERT_AFTER=3     # email you if a check fails this many runs in a row

DIR="$HOME/Scripts"
STATE="$DIR/update-check.state"
LOG="$DIR/update-check.log"
SOFA_IOS="https://sofa.macadmins.io/v2/ios_data_feed.json"
SOFA_MAC="https://sofa.macadmins.io/v2/macos_data_feed.json"

TEST=0
[ "${1:-}" = "--test" ] && TEST=1
# A file named "test-next-run" in ~/Scripts makes the next run a test run (used once, then removed)
if [ -f "$DIR/test-next-run" ]; then TEST=1; rm -f "$DIR/test-next-run"; fi
NOW=$(date +%s)

# ---------- Small helpers ----------
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  if [ -t 1 ]; then echo "$*"; fi
}

# Keep the log from growing forever: trim to the last 500 lines once it passes ~1 MB
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Read / write the memory file. In --test mode nothing is written.
get() { [ -f "$STATE" ] && grep -m1 "^$1=" "$STATE" | cut -d= -f2-; }
put() {
  [ "$TEST" -eq 1 ] && return 0
  { [ -f "$STATE" ] && grep -v "^$1=" "$STATE"; echo "$1=$2"; } > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

# Changes that should only be saved once the email has actually been sent
QUEUE=""
queue() { QUEUE="$QUEUE$1=$2"$'\n'; }
apply_queue() {
  local k v
  while IFS='=' read -r k v; do [ -n "$k" ] && put "$k" "$v"; done <<< "$QUEUE"
}

# Ask the SOFA feed (a big JSON file) a question, using macOS's built-in JavaScript.
#   sofa_query FILE latest           -> newest release of the newest OS line
#   sofa_query FILE find 27.0.2      -> the release with that version number
# Prints: version|number of actively exploited bugs|security notes URL|CVE ids
sofa_query() {
  osascript -l JavaScript - "$1" "$2" "${3:-}" <<'JXA' 2>/dev/null
ObjC.import('Foundation');
function run(argv) {
  var txt = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null));
  if (!txt) return "ERROR";
  var d = JSON.parse(txt);
  function fmt(r) {
    var ex = r.ActivelyExploitedCVEs || [];
    return [r.ProductVersion, ex.length, r.SecurityInfo || "", ex.join(" ")].join("|");
  }
  if (argv[1] === "latest") return fmt(d.OSVersions[0].Latest);
  for (var i = 0; i < d.OSVersions.length; i++) {
    var rels = [d.OSVersions[i].Latest].concat(d.OSVersions[i].SecurityReleases || []);
    for (var j = 0; j < rels.length; j++) {
      if (rels[j] && rels[j].ProductVersion === argv[2]) return fmt(rels[j]);
    }
  }
  return "NOTFOUND";
}
JXA
}

# Send an email through Apple Mail (uses the account you signed into there; no password stored here)
send_mail() {
  osascript - "$1" "$2" "$TO_ADDRESS" <<'AS'
on run argv
  set theSubject to item 1 of argv
  set theBody to item 2 of argv
  set theTo to item 3 of argv
  tell application "Mail"
    if theTo is "" then
      -- copy every account's addresses out of Mail as plain text, then pick the Gmail one
      set allAddrs to {}
      repeat with acct in (get every account)
        set allAddrs to allAddrs & (get email addresses of acct)
      end repeat
      repeat with a in allAddrs
        set addrText to (contents of a) as string
        if addrText ends with "@gmail.com" then set theTo to addrText
      end repeat
    end if
    if theTo is "" then error "No Gmail address found in Mail. Set TO_ADDRESS at the top of the script."
    set msg to make new outgoing message with properties {subject:theSubject, content:theBody, sender:theTo, visible:false}
    tell msg to make new to recipient at end of to recipients with properties {address:theTo}
    send msg
  end tell
  return theTo
end run
AS
}

BODY=""; SUBJECT_BITS=""; URGENT=0; SEND=0
add_body() { BODY="$BODY$1"$'\n\n'; }
add_subject() { if [ -z "$SUBJECT_BITS" ]; then SUBJECT_BITS="$1"; else SUBJECT_BITS="$SUBJECT_BITS + $1"; fi; }

# =====================================================================
# 1) MAC — ask Apple directly whether this Mac has an update waiting
# =====================================================================
MAC_OUT=$(softwareupdate -l 2>&1)

if echo "$MAC_OUT" | grep -q "No new software available"; then
  log "Mac: up to date"
  put MAC_FAILS 0
  put MAC_NOTIFIED ""
  [ "$TEST" -eq 1 ] && add_body "MAC: up to date."

elif echo "$MAC_OUT" | grep -q "Label:"; then
  put MAC_FAILS 0
  # Turn Apple's output into lines like "macOS Golden Gate 27.0.2 (27.0.2)"
  MAC_LIST=$(echo "$MAC_OUT" | sed -n 's/^[[:space:]]*Title: \(.*\), Version: \([^,]*\),.*/\1 (\2)/p')
  [ -z "$MAC_LIST" ] && MAC_LIST=$(echo "$MAC_OUT" | sed -n 's/^\* Label: //p')
  MAC_VERSIONS=$(echo "$MAC_OUT" | sed -n 's/^[[:space:]]*Title: .*, Version: \([^,]*\),.*/\1/p')
  MAC_KEY=$(echo "$MAC_LIST" | tr '\n' ';')

  LAST=$(get MAC_NOTIFIED); LAST_AT=$(get MAC_NOTIFIED_AT); LAST_AT=${LAST_AT:-0}
  REASON=""
  if [ "$MAC_KEY" != "$LAST" ]; then REASON="new"
  elif [ $((NOW - LAST_AT)) -ge $((REMIND_AFTER_DAYS * 86400)) ]; then REASON="reminder"
  fi
  [ "$TEST" -eq 1 ] && [ -z "$REASON" ] && REASON="test"

  if [ -n "$REASON" ]; then
    # Check SOFA's macOS feed for actively exploited bugs fixed by these updates
    EXPLOIT_NOTE="Actively exploited bugs: couldn't check (security feed unavailable)."
    NOTES_URL=""
    MAC_FEED="$DIR/.sofa_mac.json"
    if curl -fsS --max-time 60 -o "$MAC_FEED" "$SOFA_MAC"; then
      EXPLOIT_NOTE="Actively exploited bugs fixed: none reported."
      for v in $MAC_VERSIONS; do
        R=$(sofa_query "$MAC_FEED" find "$v")
        case "$R" in ERROR|NOTFOUND|"") continue ;; esac
        IFS='|' read -r _ N URL CVES <<< "$R"
        [ -n "$URL" ] && NOTES_URL="$URL"
        if [ "${N:-0}" -gt 0 ]; then
          URGENT=1
          EXPLOIT_NOTE="Actively exploited bugs fixed: $N ($CVES). Install today."
        fi
      done
    fi
    HEADER="MAC: update available"
    [ "$REASON" = "reminder" ] && HEADER="MAC REMINDER: still not installed after $REMIND_AFTER_DAYS+ days"
    SECTION="$HEADER
$(echo "$MAC_LIST" | sed 's/^/  - /')
$EXPLOIT_NOTE"
    [ -n "$NOTES_URL" ] && SECTION="$SECTION
Security notes: $NOTES_URL"
    SECTION="$SECTION
To install: System Settings > General > Software Update. Save your work and quit your apps first,
or plug in the charger, quit apps, and choose \"Try Tonight\"."
    add_body "$SECTION"
    add_subject "Mac"
    SEND=1
    queue MAC_NOTIFIED "$MAC_KEY"
    queue MAC_NOTIFIED_AT "$NOW"
    log "Mac: update available ($REASON): $MAC_KEY"
  else
    log "Mac: update still pending, already emailed: $MAC_KEY"
  fi

else
  FAILS=$(( $(get MAC_FAILS || echo 0) + 1 ))
  [ "$TEST" -eq 1 ] && FAILS=$FAIL_ALERT_AFTER
  put MAC_FAILS "$FAILS"
  log "Mac: check FAILED ($FAILS in a row): $(echo "$MAC_OUT" | tr '\n' ' ' | cut -c1-200)"
  if [ "$FAILS" -eq "$FAIL_ALERT_AFTER" ]; then
    add_body "MAC CHECK PROBLEM: the macOS update check has failed $FAILS times in a row.
Apple's tool said: $(echo "$MAC_OUT" | tail -n 3)
Check manually: System Settings > General > Software Update."
    add_subject "Mac check failing"
    SEND=1
  fi
fi

# =====================================================================
# 2) IPHONE — ask the SOFA feed what the newest iOS release is
# =====================================================================
IOS_FEED="$DIR/.sofa_ios.json"
R=""
if curl -fsS --max-time 60 -o "$IOS_FEED" "$SOFA_IOS"; then R=$(sofa_query "$IOS_FEED" latest); fi

case "$R" in
  ""|ERROR|NOTFOUND)
    FAILS=$(( $(get IOS_FAILS || echo 0) + 1 ))
    [ "$TEST" -eq 1 ] && FAILS=$FAIL_ALERT_AFTER
    put IOS_FAILS "$FAILS"
    log "iOS: feed check FAILED ($FAILS in a row)"
    if [ "$FAILS" -eq "$FAIL_ALERT_AFTER" ]; then
      add_body "IPHONE CHECK PROBLEM: couldn't read the iOS release feed ($SOFA_IOS) $FAILS times in a row.
Until this is fixed, check your iPhone manually: Settings > General > Software Update."
      add_subject "iPhone check failing"
      SEND=1
    fi
    ;;
  *)
    put IOS_FAILS 0
    IFS='|' read -r IOS_VER N URL CVES <<< "$R"
    LAST=$(get IOS_NOTIFIED)
    if [ -z "$LAST" ] && [ "$TEST" -eq 0 ]; then
      # Very first run: remember the current version without emailing
      put IOS_NOTIFIED "$IOS_VER"
      log "iOS: first run, recorded iOS $IOS_VER as already known (no email)"
    elif [ "$IOS_VER" != "$LAST" ] || [ "$TEST" -eq 1 ]; then
      if [ "${N:-0}" -gt 0 ]; then
        URGENT=1
        EXPLOIT_NOTE="Actively exploited bugs fixed: $N ($CVES). Install today."
      else
        EXPLOIT_NOTE="Actively exploited bugs fixed: none reported."
      fi
      add_body "IPHONE: iOS $IOS_VER has been released.
$EXPLOIT_NOTE
Security notes: $URL
To install now (skips Apple's weeks-long automatic rollout):
Settings > General > Software Update > Update Now. If you've already updated, ignore this."
      add_subject "iPhone (iOS $IOS_VER)"
      SEND=1
      queue IOS_NOTIFIED "$IOS_VER"
      log "iOS: new release $IOS_VER (exploited: ${N:-0})"
    else
      log "iOS: latest is $IOS_VER, already emailed"
    fi
    ;;
esac

# =====================================================================
# 3) EMAIL — only if something new came up (or in --test mode)
# =====================================================================
if [ "$TEST" -eq 1 ] && [ "$SEND" -eq 0 ]; then
  add_body "Nothing new to report."
fi

if [ "$SEND" -eq 1 ] || [ "$TEST" -eq 1 ]; then
  if [ "$URGENT" -eq 1 ]; then SUBJECT="URGENT update: ${SUBJECT_BITS} (actively exploited bug fixed)"
  else SUBJECT="Update available: ${SUBJECT_BITS:-nothing new}"; fi
  [ "$TEST" -eq 1 ] && SUBJECT="[TEST] $SUBJECT"
  BODY="$BODY--
Sent by ~/Scripts/update-check.sh on $(scutil --get ComputerName 2>/dev/null || hostname).
What it did: see ~/Scripts/update-check.log"

  if SENT_TO=$(send_mail "$SUBJECT" "$BODY" 2>&1); then
    apply_queue
    log "Email sent to $SENT_TO: $SUBJECT"
  else
    log "Email FAILED (will retry next run): $SENT_TO"
    exit 1
  fi
fi
exit 0
