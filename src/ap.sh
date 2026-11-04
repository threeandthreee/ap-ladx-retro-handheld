#!/bin/sh
# AP LADX: terminal-driven launcher for Archipelago Links Awakening DX clients (+ solo generation).
# Usage: ap.sh        open the UI in a terminal (TERMINAL_CMD from platform.conf)
#        ap.sh ui     run the UI directly in the current terminal
#        ap.sh status | stop | log

APP_DIR=$(cd "$(dirname "$0")" && pwd)

# platform.conf provides TERMINAL_CMD, LINE_WIDTH, BASE_ROM_DIRECTORY and the optional
# SAVEFILE_DIRECTORY / SAVESTATE_DIRECTORY
TERMINAL_CMD=""
LINE_WIDTH=48
BASE_ROM_DIRECTORY=""
SAVEFILE_DIRECTORY=""
SAVESTATE_DIRECTORY=""
. "$APP_DIR/platform.conf" || exit 1
[ -n "$BASE_ROM_DIRECTORY" ] || { echo "BASE_ROM_DIRECTORY is not set in platform.conf"; exit 1; }

# the ROM Archipelago patches from (name it expects) and the checksums of the known-good dump
LADX_ROM="Legend of Zelda, The - Link's Awakening DX (USA, Europe) (SGB Enhanced).gbc"
ROM_SIZE=1048576
ROM_SHA256=c95dd3d9cb798e86c28e3269554e458d434bf3277b96cadf5bc81cfacfb5ee60
ROM_SHA1=d90ac17e9bf17b6c61624ad9f05447bdb5efc01a
ROM_MD5=07c211479386825042efb4ad31bb525f

PAGE_SIZE=4
CONNECT_TIMEOUT=60   # seconds before "Connecting" turns into Failed
POLL_SECS=2          # background watchdog interval
SLEEP_GAP=20         # extra seconds beyond POLL_SECS that count as "the device slept"

PATCH_DIR="$APP_DIR/patches"
SOLO_DIR="$APP_DIR/solo_yamls"
DATA_DIR="$APP_DIR/.data"
AP_DIR="$DATA_DIR/Archipelago"
OVERRIDE_DIR="$DATA_DIR/overrides"
STATE_DIR="$DATA_DIR/state"
ROM_DIR="$BASE_ROM_DIRECTORY/APLADX"
LAUNCHER="$AP_DIR/ArchipelagoLauncher"
PID_FILE="$STATE_DIR/ap.pid"
SOLO_PID="$STATE_DIR/solo.pid"
SOLO_STATUS="$STATE_DIR/solo_status"
LOG="$STATE_DIR/ap.log"
END_FILE="$STATE_DIR/last_end"
mkdir -p "$STATE_DIR"

ESC=$(printf '\033')

say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
boot_secs() { read -r up _ < /proc/uptime; echo "${up%.*}"; }
name_of() { b=$(basename "$1"); printf '%s' "${b%.*}"; }
# the .gbc Archipelago writes next to a patch file (same name, last extension replaced)
rom_of() { b=$(basename "$1"); printf '%s/%s.gbc' "$(dirname "$1")" "${b%.*}"; }

# alive <pid>: running (a zombie that has not been reaped yet does not count)
alive() {
  [ -r "/proc/$1/stat" ] || return 1
  st=$(sed 's/^.*) //' "/proc/$1/stat" | cut -c1)
  [ "$st" != "Z" ]
}

# ---------- terminal helpers ----------
clear_screen() { printf '%s[2J%s[H' "$ESC" "$ESC"; }
# fit <text>: cut to LINE_WIDTH, ending in ... if it was too long
fit() {
  if [ "${#1}" -gt "$LINE_WIDTH" ]; then
    printf '%s...' "$(printf '%s' "$1" | cut -c1-$((LINE_WIDTH - 3)))"
  else
    printf '%s' "$1"
  fi
}
line() { printf '%s\n' "$(fit "$1")"; }
# at <row> <col> <text>: draw text at a position without moving the input cursor
at() { printf '%s7%s[%s;%sH%s%s8' "$ESC" "$ESC" "$1" "$2" "$3" "$ESC"; }
dots_str() { n=$1; s=""; while [ "$n" -gt 0 ]; do s="$s."; n=$((n - 1)); done; printf '%s' "$s"; }

# read_choice <default letter>: reads a line into $choice (lowercase). Enter alone gives the default.
read_choice() {
  read -r choice || choice="q"
  choice=$(printf '%s' "$choice" | tr 'A-Z' 'a-z' | tr -d ' \r')
  [ -n "$choice" ] || choice="$1"
}

# ask <row> <options text> <default letter> <valid letters>: shows the prompt on <row> and
# repeats until the answer is one of the valid letters; sets $choice
ask() {
  while :; do
    printf '%s[%s;1H%s[K%s > ' "$ESC" "$1" "$ESC" "$2"
    read_choice "$3"
    case " $4 " in *" $choice "*) return 0 ;; esac
  done
}

# run_step <label> <function> [success word]: runs the function while one dot per second is
# printed, then right-aligns Done (or the success word) / Failed at the end of the line
run_step() {
  label="$1"; fn="$2"; okword="${3:-Done}"; rcfile="$STATE_DIR/step.rc"
  rm -f "$rcfile"
  printf '%s' "$label"
  ( "$fn" >>"$LOG" 2>&1; echo $? > "$rcfile" ) &
  max=$((LINE_WIDTH - ${#label} - 6)); n=0
  while [ ! -f "$rcfile" ]; do
    if [ "$n" -lt "$max" ]; then printf '.'; n=$((n + 1)); fi
    sleep 1
  done
  rc=$(cat "$rcfile")
  if [ "$rc" = 0 ]; then c="$okword"; else c="Failed"; fi
  printf '%s%s\n' "$(dots_str $((LINE_WIDTH - ${#label} - ${#c} - n)))" "$c"
  [ "$rc" = 0 ]
}

# ---------- files ----------
# list_files <dir> <ext>...: existing files with those extensions, sorted
list_files() {
  dir="$1"; shift
  for e in "$@"; do
    for f in "$dir"/*."$e"; do [ -f "$f" ] && printf '%s\n' "$f"; done
  done | sort
}

has_patch() { for e in apladx apladxb; do [ -f "$PATCH_DIR/$1.$e" ] && return 0; done; return 1; }
has_source() {
  has_patch "$1" && return 0
  for e in yaml yml; do [ -f "$SOLO_DIR/$1.$e" ] && return 0; done
  return 1
}

# save_matches <file name> <rom name>: is this a save/state file belonging to that ROM?
# (Name.srm, Name.state, Name.state1, Name.state.auto, Name.state1.png ...)
save_matches() {
  case "$1" in
    "$2".*) return 0 ;;
    *)      return 1 ;;
  esac
}

wipe_saves() {
  for d in "$SAVEFILE_DIRECTORY" "$SAVESTATE_DIRECTORY"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    find "$d" -type f 2>/dev/null | while IFS= read -r f; do
      save_matches "$(basename "$f")" "$1" && rm -f "$f"
    done
  done
}

# does this file match the known-good Link's Awakening DX ROM? (size, then the strongest
# checksum tool the device has; with none, the size is all we can check)
rom_ok() {
  [ "$(wc -c < "$1" 2>/dev/null)" = "$ROM_SIZE" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$ROM_SHA256" ]
  elif command -v sha1sum >/dev/null 2>&1; then [ "$(sha1sum "$1" | cut -d' ' -f1)" = "$ROM_SHA1" ]
  elif command -v md5sum >/dev/null 2>&1; then [ "$(md5sum "$1" | cut -d' ' -f1)" = "$ROM_MD5" ]
  else return 0; fi
}

# base ROM candidates: .gbc files with "Awakening ... DX" in the name, in the app folder or anywhere
# under the base ROM directory (our own ROM folder is skipped)
rom_candidates() {
  for f in "$APP_DIR"/*Awakening*DX*.[gG][bB][cC]; do [ -f "$f" ] && printf '%s\n' "$f"; done
  find "$BASE_ROM_DIRECTORY" -path "$ROM_DIR" -prune -o -type f -name '*Awakening*DX*.[gG][bB][cC]' -print 2>/dev/null
}

# is there a base ROM candidate dropped into the app folder?
has_dropin_rom() {
  for f in "$APP_DIR"/*Awakening*DX*.[gG][bB][cC]; do [ -f "$f" ] && return 0; done
  return 1
}

# the room address stored in a patch file (its archipelago.json manifest), if any
patch_server() {
  unzip -p "$1" archipelago.json 2>/dev/null \
    | sed -n 's/.*"server"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# the address must be HOST:PORT (a port is always required)
valid_addr() {
  case "$1" in
    ""|*[!A-Za-z0-9.:_-]*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  case "${1##*:}" in
    ""|*[!0-9]*) return 1 ;;
  esac
  return 0
}

ap_version() {
  tr -d ' \t\r\n' < "$AP_DIR/manifest.json" 2>/dev/null \
    | sed -n 's/.*"version":\[\([0-9]*\),\([0-9]*\),\([0-9]*\)\].*/\1.\2.\3/p'
}

world_version() {
  w="$AP_DIR/custom_worlds/ladx_beta.apworld"
  for p in archipelago.json ladx_beta/archipelago.json; do
    v=$(unzip -p "$w" "$p" 2>/dev/null | sed -n 's/.*"world_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
}

# ---------- processes ----------
is_running() {
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "ap.sh" || return 1
}

solo_running() {
  [ -f "$SOLO_PID" ] || return 1
  pid=$(cat "$SOLO_PID" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "ap.sh" || return 1
}

# true if an established TCP connection has the room's port as its remote port
connected() {
  hex=$(printf '%04X' "${1##*:}")
  for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    while read -r _ _ remote st _; do
      [ "$st" = "01" ] && [ "${remote##*:}" = "$hex" ] && return 0
    done < "$f"
  done
  return 1
}

# patching | patchfailed | connecting | failed | connected | stopped
client_status() {
  ph=$(cat "$STATE_DIR/phase" 2>/dev/null)
  if ! is_running; then
    if [ "$ph" = "patching" ]; then echo patchfailed; else echo stopped; fi
    return
  fi
  [ "$ph" = "patching" ] && { echo patching; return; }
  if connected "$(cat "$STATE_DIR/addr" 2>/dev/null)"; then echo connected
  elif [ $(( $(boot_secs) - $(cat "$STATE_DIR/started" 2>/dev/null || echo 0) )) -lt "$CONNECT_TIMEOUT" ]; then echo connecting
  else echo failed; fi
}

# generating | genfailed | patching | patchfailed | completed
solo_status() {
  s=$(cat "$SOLO_STATUS" 2>/dev/null)
  if ! solo_running; then               # the process died without finishing
    case "$s" in
      generating) s=genfailed ;;
      patching)   s=patchfailed ;;
    esac
  fi
  echo "${s:-genfailed}"
}

# step_state <status> <step 1|2> for each progress screen: pending | running | done | failed
client_step() {
  case "$2:$1" in
    1:patching) echo running ;;
    1:patchfailed) echo failed ;;
    1:*) echo done ;;
    2:patching|2:patchfailed) echo pending ;;
    2:connecting) echo running ;;
    2:connected) echo done ;;
    2:*) echo failed ;;
  esac
}
solo_step() {
  case "$2:$1" in
    1:generating) echo running ;;
    1:genfailed) echo failed ;;
    1:*) echo done ;;
    2:generating|2:genfailed) echo pending ;;
    2:patching) echo running ;;
    2:completed) echo done ;;
    2:*) echo failed ;;
  esac
}

# stop_proc <pid file> <running check>
stop_proc() {
  pidfile="$1"; check="$2"
  if ! "$check"; then rm -f "$pidfile"; return 0; fi
  pid=$(cat "$pidfile")
  kill -s TERM -- "-$pid" 2>/dev/null || kill -s TERM "$pid" 2>/dev/null
  i=0
  while "$check" && [ $i -lt 5 ]; do sleep 1; i=$((i + 1)); done
  "$check" && { kill -s KILL -- "-$pid" 2>/dev/null; rm -f "$pidfile"; }
  return 0
}
do_stop() { stop_proc "$PID_FILE" is_running; rm -f "$END_FILE"; echo stopped > "$STATE_DIR/phase"; say "Stopped"; }
solo_stop() { stop_proc "$SOLO_PID" solo_running; }

# ---------- setup actions (each runs behind a "label.....Done" line) ----------
install_archipelago() {
  tb="$1"
  say "Installing Archipelago from $tb"
  tmp="$DATA_DIR/install.tmp"; bak="$DATA_DIR/backup.tmp"
  rm -rf "$tmp" "$bak"; mkdir -p "$tmp" "$bak"
  # tar on some devices has no -z, so decompress with gzip and pipe into plain tar
  if (cd "$tmp" && gzip -dc "$tb" | tar -xf -) && [ -d "$tmp/Archipelago" ]; then
    if [ -d "$AP_DIR" ]; then                   # keep the user's data from the old install
      [ -d "$AP_DIR/custom_worlds" ] && cp -pR "$AP_DIR/custom_worlds" "$bak/"
      [ -f "$AP_DIR/host.yaml" ] && cp -p "$AP_DIR/host.yaml" "$bak/"
      [ -f "$AP_DIR/$LADX_ROM" ] && cp -p "$AP_DIR/$LADX_ROM" "$bak/"
    fi
    rm -rf "$AP_DIR"
    mv "$tmp/Archipelago" "$AP_DIR"
    if [ -d "$bak/custom_worlds" ]; then rm -rf "$AP_DIR/custom_worlds"; cp -pR "$bak/custom_worlds" "$AP_DIR/"; fi
    [ -f "$bak/host.yaml" ] && cp -p "$bak/host.yaml" "$AP_DIR/host.yaml"
    [ -f "$bak/$LADX_ROM" ] && cp -p "$bak/$LADX_ROM" "$AP_DIR/$LADX_ROM"
    rm -f "$tb"
    rm -rf "$tmp" "$bak"
    return 0
  fi
  mv "$tb" "$tb.failed" 2>/dev/null
  rm -rf "$tmp" "$bak"
  return 1
}

act_archipelago() {
  rc=0
  for tb in "$APP_DIR"/*.tar.gz; do
    [ -f "$tb" ] || continue
    install_archipelago "$tb" || rc=1
  done
  return $rc
}

act_hostyaml() {
  [ -d "$AP_DIR" ] && mv -f "$APP_DIR/host.yaml" "$AP_DIR/host.yaml"
}

act_baserom() {
  [ -d "$AP_DIR" ] || return 1
  f=$(rom_candidates | while IFS= read -r c; do rom_ok "$c" && { printf '%s' "$c"; break; }; done)
  [ -n "$f" ] || return 1
  case "$f" in
    "$APP_DIR"/*) mv -f "$f" "$AP_DIR/$LADX_ROM" ;;     # a dropped-in file is consumed
    *) cp -f "$f" "$AP_DIR/$LADX_ROM" ;;                # the copy in the ROM library is left alone
  esac
}

act_world() {
  [ -d "$AP_DIR" ] || return 1
  mkdir -p "$AP_DIR/custom_worlds" && mv -f "$APP_DIR/ladx_beta.apworld" "$AP_DIR/custom_worlds/ladx_beta.apworld"
}

is_ready() { [ -x "$LAUNCHER" ] && [ -f "$AP_DIR/$LADX_ROM" ]; }

# ROMs whose patch/solo yaml is gone (and their saves), and overrides whose patch is gone
tidy_up() {
  mkdir -p "$PATCH_DIR" "$SOLO_DIR" "$ROM_DIR" "$OVERRIDE_DIR" "$STATE_DIR"
  for f in "$ROM_DIR"/*.gbc; do
    [ -f "$f" ] || continue
    n=$(name_of "$f")
    has_source "$n" || { rm -f "$f"; wipe_saves "$n"; }
  done
  for f in "$OVERRIDE_DIR"/*; do
    [ -f "$f" ] || continue
    has_patch "$(basename "$f")" || rm -f "$f"
  done
}

# ---------- client process ----------
# start_client <patch> <--connect address or ""> <password> <room address> <name>
start_client() {
  command -v setsid >/dev/null 2>&1 || { say "setsid missing"; return 1; }
  : > "$LOG"
  rm -f "$END_FILE" "$STATE_DIR/started"
  printf '%s' "$4" > "$STATE_DIR/addr"
  printf '%s' "$5" > "$STATE_DIR/name"
  echo patching > "$STATE_DIR/phase"
  setsid sh "$APP_DIR/ap.sh" _run "$1" "$2" "$3" >>"$LOG" 2>&1 </dev/null &
  sleep 1
  is_running
}

# internal: runs detached in its own session; $$ is the process-group id
do_run() {
  patch="$1"; connect="$2"; password="$3"
  echo $$ > "$PID_FILE"
  trap cleanup TERM INT HUP
  cd "$AP_DIR" || exit 1
  rom_out=$(rom_of "$patch"); rom_size=""; rom_done=0
  rm -f "$rom_out"                         # never pick up a stale ROM from an earlier attempt
  set -- "$patch" -- --nogui               # the client is always started from the patch (it re-patches the ROM)
  [ -n "$connect" ] && set -- "$@" --connect "$connect"
  [ -n "$password" ] && set -- "$@" --password "$password"
  "$LAUNCHER" "$@" &
  child=$!
  last=$(boot_secs)
  while alive "$child"; do
    sleep "$POLL_SECS"
    now=$(boot_secs)
    if [ $((now - last)) -gt $((POLL_SECS + SLEEP_GAP)) ]; then
      say "Suspend detected ($((now - last))s gap), closing client"
      echo "closed because the device slept" > "$END_FILE"
      cleanup
    fi
    last=$now
    # once the patched ROM has finished being written, file it (that ends the "patching" phase)
    if [ "$rom_done" = 0 ] && [ -f "$rom_out" ]; then
      size=$(wc -c < "$rom_out")
      [ "$size" = "$rom_size" ] && rom_patched
      rom_size=$size
    fi
  done
  wait "$child"; code=$?
  [ "$rom_done" = 0 ] && [ -f "$rom_out" ] && rom_patched    # the client may stop right after the ROM was made
  say "Client exited (code $code)"
  echo "client exited, code $code" > "$END_FILE"
  rm -f "$PID_FILE"
}

# move the finished ROM into the ROM directory and start the connection phase
rom_patched() {
  if mv -f "$rom_out" "$ROM_DIR/"; then
    say "Moved $(basename "$rom_out") to the ROM directory"
    rom_done=1
    printf '%s' "$(boot_secs)" > "$STATE_DIR/started"
    echo patched > "$STATE_DIR/phase"
  fi
}

cleanup() {
  trap '' TERM INT HUP
  rm -f "$PID_FILE"
  kill -s TERM -- "-$$" 2>/dev/null
  sleep 2
  kill -s KILL -- "-$$" 2>/dev/null
  exit 0
}

# ---------- solo generation ----------
solo_fail() {
  status="$1"; shift
  say "Solo failed ($status): $*"
  echo "$status" > "$SOLO_STATUS"
  rm -f "$SOLO_PID"
  exit 1
}

solo_abort() {
  trap '' TERM INT HUP
  rm -f "$SOLO_PID"
  [ -n "$romchild" ] && kill -s TERM -- "-$romchild" 2>/dev/null
  kill -s TERM -- "-$$" 2>/dev/null
  sleep 1
  [ -n "$romchild" ] && kill -s KILL -- "-$romchild" 2>/dev/null
  kill -s KILL -- "-$$" 2>/dev/null
  exit 1
}

# internal: generate a solo game from a yaml, patch a ROM from the result, and file the ROM.
# Runs detached in its own session. Status: generating -> (genfailed) -> patching -> (patchfailed) -> completed
do_solo() {
  yaml="$1"; name=$(name_of "$yaml"); romchild=""
  echo $$ > "$SOLO_PID"
  trap solo_abort TERM INT HUP
  echo generating > "$SOLO_STATUS"
  cd "$AP_DIR" || solo_fail genfailed "no Archipelago folder"

  mkdir -p Players
  for f in Players/*; do [ -f "$f" ] && rm -f "$f"; done      # only this yaml may be in Players
  cp "$yaml" "Players/" || solo_fail genfailed "could not copy the yaml"
  rm -rf output; mkdir -p output                               # output must start empty

  say "Running Generate"
  "$LAUNCHER" "Generate" </dev/null
  zip=$(ls "$AP_DIR"/output/*.zip 2>/dev/null | head -n 1)
  [ -n "$zip" ] || solo_fail genfailed "Generate produced no output zip"
  unzip -o "$zip" -d "$AP_DIR/output" || solo_fail genfailed "could not unzip $zip"
  rm -f "$zip"
  # the patch is the first .apladx or .apladxb file in the output
  patch=$(find "$AP_DIR/output" -type f \( -name '*.apladx' -o -name '*.apladxb' \) | sort | head -n 1)
  [ -n "$patch" ] || solo_fail genfailed "no .apladx/.apladxb patch in the generation output"

  # patch a ROM from it (no connection info); the client that starts is stopped afterwards
  echo patching > "$SOLO_STATUS"
  rom=$(rom_of "$patch"); size=""; got=0
  say "Patching a ROM from $(basename "$patch")"
  setsid "$LAUNCHER" "$patch" -- --nogui </dev/null &
  romchild=$!
  while alive "$romchild"; do
    if [ -f "$rom" ]; then
      s=$(wc -c < "$rom")
      [ "$s" = "$size" ] && { got=1; break; }
      size=$s
    fi
    sleep 2
  done
  [ "$got" = 1 ] || [ -f "$rom" ] || solo_fail patchfailed "the ROM was not created"
  kill -s TERM -- "-$romchild" 2>/dev/null
  sleep 1
  kill -s KILL -- "-$romchild" 2>/dev/null
  romchild=""

  mv -f "$rom" "$ROM_DIR/$name.gbc" || solo_fail patchfailed "could not move the ROM"
  wipe_saves "$name"
  rm -f "$patch"
  say "Solo ROM ready: $name.gbc"
  echo completed > "$SOLO_STATUS"
  rm -f "$SOLO_PID"
}

# ---------- screens ----------
# progress_poller <status fn> <step fn> <row1> <label1> <row2> <label2>: draws the two steps
# "label......Done" in place, one dot per second while a step runs, until it is killed
progress_poller() {
  sfn="$1"; stfn="$2"; r1="$3"; l1="$4"; r2="$5"; l2="$6"
  d1=0; d2=0; shown1=0; shown2=0
  while :; do
    st=$("$sfn")
    if [ "$d1" -ge 0 ]; then
      s=$("$stfn" "$st" 1)
      [ "$s" != "pending" ] && [ "$shown1" = 0 ] && { at "$r1" 1 "$l1"; shown1=1; }
      draw_step "$r1" "$l1" "$d1" "$s"; d1=$NEWDOTS
    fi
    if [ "$d2" -ge 0 ]; then
      s=$("$stfn" "$st" 2)
      [ "$s" != "pending" ] && [ "$shown2" = 0 ] && { at "$r2" 1 "$l2"; shown2=1; }
      draw_step "$r2" "$l2" "$d2" "$s"; d2=$NEWDOTS
    fi
    [ "$d1" -lt 0 ] && [ "$d2" -lt 0 ] && break
    sleep 1
  done
}

# draw_step <row> <label> <dots so far> <state>: adds a dot (running) or the conclusion
# (done/failed); sets NEWDOTS to the new dot count, -1 once the line is finished
draw_step() {
  row="$1"; label="$2"; dots="$3"; state="$4"
  case "$state" in
    running)
      max=$((LINE_WIDTH - ${#label} - 6))
      if [ "$dots" -lt "$max" ]; then at "$row" $((${#label} + dots + 1)) "."; dots=$((dots + 1)); fi ;;
    done|failed)
      if [ "$state" = "done" ]; then c="Done"; else c="Failed"; fi
      at "$row" $((${#label} + dots + 1)) "$(dots_str $((LINE_WIDTH - ${#label} - ${#c} - dots)))$c"
      dots=-1 ;;
  esac
  NEWDOTS=$dots
}

# run_progress <status fn> <step fn> <row1> <label1> <row2> <label2> <prompt row> <abort fn>
# the prompt is on <prompt row>; (a)bort stops the process, Enter/q leaves it running
run_progress() {
  progress_poller "$1" "$2" "$3" "$4" "$5" "$6" &
  poller=$!
  while :; do
    printf '%s[%s;1H%s[K(a)bort | (Q)uit (continues in background) > ' "$ESC" "$7" "$ESC"
    read_choice q
    case "$choice" in
      a) "$8"; break ;;
      q) break ;;
    esac
  done
  kill "$poller" 2>/dev/null
  wait "$poller" 2>/dev/null
}

# the first screen: install/update whatever was dropped into the app folder
# returns 0 to continue to the next screen, 1 to quit
setup_screen() {
  tb=$(for t in "$APP_DIR"/*.tar.gz; do [ -f "$t" ] && echo "$t"; done | head -n 1)
  ap_will_exist=0; { [ -x "$LAUNCHER" ] || [ -n "$tb" ]; } && ap_will_exist=1
  need_host=0; need_rom=0; need_world=0
  if [ "$ap_will_exist" = 1 ]; then
    [ -f "$APP_DIR/host.yaml" ] && need_host=1
    { [ ! -f "$AP_DIR/$LADX_ROM" ] || has_dropin_rom; } && need_rom=1
    [ -f "$APP_DIR/ladx_beta.apworld" ] && need_world=1
  fi
  [ -n "$tb" ] && need_ap=1 || need_ap=0

  if [ "$need_ap$need_host$need_rom$need_world" = "0000" ]; then      # nothing to do: skip the screen
    is_ready && return 0
    clear_screen
    if [ ! -x "$LAUNCHER" ]; then line "Archipelago is not installed."; line "Put its .tar.gz in the app folder."
    else line "Base ROM not found."; line "Put the .gbc in the app folder."; fi
    printf '(Q)uit > '; read -r _
    return 1
  fi

  clear_screen; rows=0
  if [ "$need_ap" = 1 ]; then
    if [ -x "$LAUNCHER" ]; then l="Updating Archipelago"; else l="Installing Archipelago"; fi
    run_step "$l" act_archipelago; rows=$((rows + 1))
  fi
  if [ "$need_host" = 1 ]; then run_step "Updating host.yaml" act_hostyaml; rows=$((rows + 1)); fi
  if [ "$need_rom" = 1 ]; then run_step "Looking for base ROM" act_baserom Found; rows=$((rows + 1)); fi
  if [ "$need_world" = 1 ]; then
    if [ -f "$AP_DIR/custom_worlds/ladx_beta.apworld" ]; then l="Updating ladx_beta"; else l="Installing ladx_beta"; fi
    run_step "$l" act_world; rows=$((rows + 1))
  fi
  if is_ready; then
    ask $((rows + 1)) "(C)ontinue | (q)uit" c "c q"
    [ "$choice" = "c" ] && return 0
    return 1
  fi
  printf '(Q)uit > '; read -r _
  return 1
}

# the second screen: versions and what is running. returns 0 to continue, 1 to quit
info_screen() {
  clear_screen; rows=0
  v=$(ap_version); line "Archipelago ${v:-(unknown version)}"; rows=$((rows + 1))
  if [ -f "$AP_DIR/custom_worlds/ladx_beta.apworld" ]; then
    v=$(world_version); line "LADX Beta ${v:-(unknown version)}"; rows=$((rows + 1))
  fi
  what=""
  if is_running; then line "Client is running"; what="client"
  elif solo_running; then line "Generator is running"; what="generator"
  elif [ -f "$END_FILE" ] && grep -q slept "$END_FILE"; then line "Client is not running (device slept)"; rm -f "$END_FILE"
  else line "Client is not running"; fi
  rows=$((rows + 1))
  if [ -n "$what" ]; then
    ask $((rows + 1)) "(T)erminate $what | (q)uit" t "t q"
    if [ "$choice" = "t" ]; then
      if [ "$what" = "client" ]; then do_stop; else solo_stop; fi
    fi
    return 1                                    # quit after terminating
  fi
  ask $((rows + 1)) "(C)ontinue | (q)uit" c "c q"
  [ "$choice" = "c" ]
}

# choose <file list> <allow (s)olo: 1|0> <line shown when empty> <second line>
# pages of 4, numbered continuously; returns 0 and sets $picked, 1 = quit, 2 = solo
choose() {
  list="$1"; allow_solo="$2"; page=0
  count=$(printf '%s' "$list" | grep -c .)
  pages=$(( (count + PAGE_SIZE - 1) / PAGE_SIZE ))
  while :; do
    clear_screen; rows=0
    if [ "$count" -eq 0 ]; then
      line "$3"; line "$4"; rows=2
    else
      first=$((page * PAGE_SIZE + 1))
      printf '%s\n' "$list" | sed -n "${first},$((first + PAGE_SIZE - 1))p" | {
        n=$first
        while IFS= read -r f; do line "($n) $(basename "$f")"; n=$((n + 1)); done
      }
      rows=$(( count - first + 1 )); [ "$rows" -gt "$PAGE_SIZE" ] && rows=$PAGE_SIZE
    fi
    opts=""; valid="q"; def="q"
    if [ "$pages" -gt 1 ]; then opts="(M)ore | "; valid="m q"; def="m"; fi
    if [ "$allow_solo" = 1 ]; then opts="$opts(s)olo | "; valid="$valid s"; fi
    if [ "$def" = "m" ]; then opts="$opts(q)uit"; else opts="$opts(Q)uit"; fi
    printf '%s[%s;1H%s[K%s > ' "$ESC" $((rows + 1)) "$ESC" "$opts"
    read_choice "$def"
    case "$choice" in
      q) return 1 ;;
      m) [ "$pages" -gt 1 ] && page=$(( (page + 1) % pages )) ;;
      s) [ "$allow_solo" = 1 ] && return 2 ;;
      *[!0-9]*) ;;
      *) if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
           picked=$(printf '%s\n' "$list" | sed -n "${choice}p")
           return 0
         fi ;;
    esac
  done
}

# the room address, then the password, then the progress screen. returns 0 once a client was started
select_patch() {
  patch="$1"; fname=$(basename "$patch"); name=$(name_of "$patch")
  ovr="$OVERRIDE_DIR/$name"
  server=$(patch_server "$patch")
  if [ -f "$ovr" ]; then default=$(cat "$ovr"); else default="$server"; fi

  msg="Enter room address or use default:"
  while :; do
    clear_screen; line "$fname"; line "$msg"; line "${default:-(none)}"
    printf '> '
    read -r typed || return 1
    typed=$(printf '%s' "${typed:-$default}" | tr -d ' \r')
    valid_addr "$typed" && break
    msg="Invalid address (HOST:PORT). Try again:"
  done
  addr="$typed"
  if [ "$addr" = "$server" ]; then rm -f "$ovr"; else printf '%s' "$addr" > "$ovr"; fi

  clear_screen; line "$fname"; line "$addr"; line "Enter password:"
  printf '> '
  read -r password || password=""

  if [ -f "$ovr" ]; then connect="$addr"; else connect=""; fi     # the patch carries its own address
  clear_screen; line "$fname"; line "$addr"
  if ! start_client "$patch" "$connect" "$password" "$addr" "$name"; then
    line "The client failed to start."
    printf '(Q)uit > '; read -r _
    return 0
  fi
  run_progress client_status client_step 3 "Patching" 4 "Connecting" 5 do_stop
  return 0
}

solo_flow() {
  yaml="$1"; fname=$(basename "$yaml")
  clear_screen; line "$fname"
  if ! command -v setsid >/dev/null 2>&1; then
    line "setsid is missing on this device."
    printf '(Q)uit > '; read -r _
    return 0
  fi
  : > "$LOG"; rm -f "$SOLO_STATUS"
  setsid sh "$APP_DIR/ap.sh" _solo "$yaml" >>"$LOG" 2>&1 </dev/null &
  sleep 1
  run_progress solo_status solo_step 2 "Generating" 3 "Patching" 4 solo_stop
  return 0
}

do_ui() {
  if ! is_running && ! solo_running; then
    tidy_up
    setup_screen || return
  fi
  info_screen || return
  while :; do
    list=$(list_files "$PATCH_DIR" apladx apladxb)
    choose "$list" 1 "No patch files found." "Put .apladx/.apladxb files in patches/."
    case $? in
      0) select_patch "$picked" && return ;;
      2)
        ylist=$(list_files "$SOLO_DIR" yaml yml)
        choose "$ylist" 0 "No yaml files found." "Put .yaml files in solo_yamls/." || return
        solo_flow "$picked" && return ;;
      *) return ;;
    esac
  done
}

launch() {
  if [ -n "$TERMINAL_CMD" ]; then
    $TERMINAL_CMD sh "$APP_DIR/ap.sh" ui      # word-splitting of TERMINAL_CMD is intended
  else
    sh "$APP_DIR/ap.sh" ui
  fi
}

case "$1" in
  ""|launch) launch ;;
  ui)     do_ui ;;
  _run)   shift; do_run "$@" ;;
  _solo)  shift; do_solo "$@" ;;
  status) client_status ;;
  stop)   do_stop ;;
  log)    tail -n 50 "$LOG" ;;
  *)      echo "usage: $0 [ui | status | stop | log]"; exit 1 ;;
esac
