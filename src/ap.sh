#!/bin/sh
# AP LADX: terminal-driven launcher for Archipelago Links Awakening DX clients (+ solo generation).
# Usage: ap.sh        open the UI in a terminal (TERMINAL_CMD from platform.conf)
#        ap.sh ui     run the UI directly in the current terminal
#        ap.sh status | stop | log

APP_DIR=$(cd "$(dirname "$0")" && pwd)

# platform.conf provides TERMINAL_CMD, BASE_ROM_DIRECTORY, SAVEFILE_DIRECTORY and SAVESTATE_DIRECTORY
TERMINAL_CMD=""
BASE_ROM_DIRECTORY=""
SAVEFILE_DIRECTORY=""
SAVESTATE_DIRECTORY=""
. "$APP_DIR/platform.conf" || exit 1
[ -n "$BASE_ROM_DIRECTORY" ] || { echo "BASE_ROM_DIRECTORY is not set in platform.conf"; exit 1; }

LADX_ROM="Legend of Zelda, The - Link's Awakening DX (USA, Europe) (SGB Enhanced).gbc"
PAGE_SIZE=5
CONNECT_TIMEOUT=60   # seconds before "Connecting..." becomes "Failed to connect"
POLL_SECS=5          # background watchdog interval
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
PAUSE=0
note=""

say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
boot_secs() { read -r up _ < /proc/uptime; echo "${up%.*}"; }
clear_screen() { printf '%s[2J%s[H' "$ESC" "$ESC"; }
name_of() { b=$(basename "$1"); printf '%s' "${b%.*}"; }
# the .gbc Archipelago writes next to a patch file (same name, last extension replaced)
rom_of() { b=$(basename "$1"); printf '%s/%s.gbc' "$(dirname "$1")" "${b%.*}"; }

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

# ---------- helpers ----------
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

# the room address stored in a patch file (its archipelago.json manifest), if any
patch_server() {
  unzip -p "$1" archipelago.json 2>/dev/null \
    | sed -n 's/.*"server"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# save_matches <file name> <rom name>: is this a save/state file belonging to that ROM?
# (Name.srm, Name.state, Name.state1, Name.state.auto, Name.state1.png ...)
save_matches() {
  b1=${1%.*}
  [ "$b1" = "$2" ] && return 0
  case "${b1##*.}" in
    state*) [ "${b1%.*}" = "$2" ] && return 0 ;;
  esac
  return 1
}

wipe_saves() {
  for d in "$SAVEFILE_DIRECTORY" "$SAVESTATE_DIRECTORY"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    find "$d" -type f 2>/dev/null | while IFS= read -r f; do
      save_matches "$(basename "$f")" "$1" && rm -f "$f"
    done
  done
}

# connecting | connected | failed | stopped
client_status() {
  is_running || { echo stopped; return; }
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

status_text() {
  case "$1" in
    connecting)  echo "Connecting..." ;;
    connected)   echo "Connected" ;;
    failed)      echo "Failed to connect" ;;
    generating)  echo "Generating..." ;;
    genfailed)   echo "Generation failed" ;;
    patching)    echo "Patching..." ;;
    patchfailed) echo "Patching failed" ;;
    completed)   echo "Completed" ;;
    *)           echo "Client closed" ;;
  esac
}

# ---------- setup: runs at launch, before the menu ----------
ui_note() { say "$*"; printf '%s\n' "$*"; PAUSE=1; }

install_archipelago() {
  tb="$1"
  ui_note "Installing Archipelago from $(basename "$tb") (this can take a while)..."
  tmp="$DATA_DIR/install.tmp"; bak="$DATA_DIR/backup.tmp"
  rm -rf "$tmp" "$bak"; mkdir -p "$tmp" "$bak"
  # tar on some devices has no -z, so decompress with gzip and pipe into plain tar
  if (cd "$tmp" && gzip -dc "$tb" | tar -xf -) >>"$LOG" 2>&1 && [ -d "$tmp/Archipelago" ]; then
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
    ui_note "Archipelago installed."
  else
    mv "$tb" "$tb.failed" 2>/dev/null
    ui_note "Could not unpack $(basename "$tb") (renamed to .failed). See the log."
  fi
  rm -rf "$tmp" "$bak"
}

setup() {
  clear_screen; printf 'AP LADX\n\n'
  mkdir -p "$PATCH_DIR" "$SOLO_DIR" "$ROM_DIR" "$OVERRIDE_DIR" "$STATE_DIR" || return 1

  # ROMs whose patch/solo yaml is gone (and their saves), and overrides whose patch is gone
  for f in "$ROM_DIR"/*.gbc; do
    [ -f "$f" ] || continue
    n=$(name_of "$f")
    has_source "$n" || { rm -f "$f"; wipe_saves "$n"; }
  done
  for f in "$OVERRIDE_DIR"/*; do
    [ -f "$f" ] || continue
    has_patch "$(basename "$f")" || rm -f "$f"
  done

  # update files dropped into the app folder: a new Archipelago build first...
  for tb in "$APP_DIR"/*.tar.gz; do
    [ -f "$tb" ] || continue
    install_archipelago "$tb"
  done

  # ...then everything that goes inside the install
  if [ -d "$AP_DIR" ]; then
    if [ -f "$APP_DIR/host.yaml" ]; then
      mv -f "$APP_DIR/host.yaml" "$AP_DIR/host.yaml" && ui_note "Installed host.yaml"
    fi
    for w in "$APP_DIR"/*.apworld; do
      [ -f "$w" ] || continue
      mkdir -p "$AP_DIR/custom_worlds"
      mv -f "$w" "$AP_DIR/custom_worlds/" && ui_note "Installed $(basename "$w")"
    done
    if [ -f "$APP_DIR/$LADX_ROM" ]; then
      mv -f "$APP_DIR/$LADX_ROM" "$AP_DIR/$LADX_ROM" && ui_note "Installed the base ROM"
    fi
    if [ ! -f "$AP_DIR/$LADX_ROM" ]; then       # otherwise look for it in the ROM library
      found=$(find "$BASE_ROM_DIRECTORY" -name "$LADX_ROM" 2>/dev/null | head -n 1)
      if [ -n "$found" ] && cp "$found" "$AP_DIR/$LADX_ROM"; then
        ui_note "Copied the base ROM from $found"
      fi
    fi
  fi
  [ "$PAUSE" = 1 ] && sleep 2
  return 0
}

# ---------- client process ----------
# start_client <patch> <--connect address or ""> <password> <room address> <name>
start_client() {
  command -v setsid >/dev/null 2>&1 || { say "setsid missing"; return 1; }
  : > "$LOG"
  rm -f "$END_FILE"
  printf '%s' "$4" > "$STATE_DIR/addr"
  printf '%s' "$5" > "$STATE_DIR/name"
  printf '%s' "$(boot_secs)" > "$STATE_DIR/started"
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
  while kill -0 "$child" 2>/dev/null; do
    sleep "$POLL_SECS"
    now=$(boot_secs)
    if [ $((now - last)) -gt $((POLL_SECS + SLEEP_GAP)) ]; then
      say "Suspend detected ($((now - last))s gap), closing client"
      echo "closed because the device slept" > "$END_FILE"
      cleanup
    fi
    last=$now
    # move the patched ROM into the ROM directory once it has finished being written
    if [ "$rom_done" = 0 ] && [ -f "$rom_out" ]; then
      size=$(wc -c < "$rom_out")
      if [ "$size" = "$rom_size" ]; then
        mv -f "$rom_out" "$ROM_DIR/" && say "Moved $(basename "$rom_out") to the ROM directory"
        rom_done=1
      fi
      rom_size=$size
    fi
  done
  wait "$child"; code=$?
  say "Client exited (code $code)"
  echo "client exited, code $code" > "$END_FILE"
  rm -f "$PID_FILE"
}

cleanup() {
  trap '' TERM INT HUP
  rm -f "$PID_FILE"
  kill -s TERM -- "-$$" 2>/dev/null
  sleep 2
  kill -s KILL -- "-$$" 2>/dev/null
  exit 0
}

# stop_group <pid file> <running check>
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
do_stop() { stop_proc "$PID_FILE" is_running; rm -f "$END_FILE"; say "Stopped"; }
solo_stop() { stop_proc "$SOLO_PID" solo_running; }

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
# Runs detached in its own session; the UI kills it if the user quits early.
# Status progression: generating -> (genfailed) -> patching -> (patchfailed) -> completed
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
  # the patch is the first output file that is not a .txt or .archipelago file
  patch=$(find "$AP_DIR/output" -type f | sort | while IFS= read -r f; do
    case "$f" in *.txt|*.archipelago) ;; *) printf '%s' "$f"; break ;; esac
  done)
  [ -n "$patch" ] || solo_fail genfailed "no patch file in the generation output"

  # patch a ROM from it (no connection info); the client that starts is stopped afterwards
  echo patching > "$SOLO_STATUS"
  rom=$(rom_of "$patch"); size=""; got=0
  say "Patching a ROM from $(basename "$patch")"
  setsid "$LAUNCHER" "$patch" -- --nogui </dev/null &
  romchild=$!
  while kill -0 "$romchild" 2>/dev/null; do
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
# keeps the status line (printed <up> lines above the cursor) up to date until killed
status_poller() {
  up="$1"; fn="$2"; shown=""
  while :; do
    s=$("$fn")
    if [ "$s" != "$shown" ]; then
      printf '%s7%s[%sA\r%s[K%s%s8' "$ESC" "$ESC" "$up" "$ESC" "$(status_text "$s")" "$ESC"
      shown="$s"
    fi
    sleep 1
  done
}

# read_with_status <lines up to the status line> <status function>: waits for a line, sets $reply
read_with_status() {
  status_poller "$1" "$2" &
  poller=$!
  read -r reply || reply="eof"
  kill "$poller" 2>/dev/null
  wait "$poller" 2>/dev/null
}

screen_started() {   # <name> <note>
  clear_screen
  printf 'AP LADX - %s\n' "$1"
  [ -n "$2" ] && printf '%s\n' "$2"
  printf '\n%s\n\n' "$(status_text connecting)"
  printf 'Press enter to exit at any time, the client will\ncontinue connecting and remain running.\nRun AP LADX again to close it.\n'
  read_with_status 5 client_status
}

screen_running() {
  clear_screen
  printf 'AP LADX - %s\n\n' "$(cat "$STATE_DIR/name" 2>/dev/null)"
  printf '%s\n\n' "$(status_text "$(client_status)")"
  printf 'Press enter to terminate the client.\nEnter 1 to exit.\n'
  read_with_status 4 client_status
  if [ -z "$reply" ]; then
    do_stop
    printf '\nClient terminated.\n'
    sleep 2
  fi
}

# returns 0 if a client was started, 1 to go back to the menu
select_patch() {
  patch="$1"; name=$(name_of "$patch")
  ovr="$OVERRIDE_DIR/$name"
  server=$(patch_server "$patch")
  if [ -f "$ovr" ]; then default=$(cat "$ovr"); src="your saved address"; else default="$server"; src="from the patch"; fi

  clear_screen
  printf 'AP LADX - %s\n\n' "$name"
  while :; do
    if [ -n "$default" ]; then
      printf 'Room address (%s): %s\nPress Enter to use it, or type a different address.\n> ' "$src" "$default"
    else
      printf 'This patch has no room address.\nType the room address as HOST:PORT.\n> '
    fi
    read -r typed || return 1
    typed=$(printf '%s' "${typed:-$default}" | tr -d ' \r')
    valid_addr "$typed" && break
    printf '\nThat is not HOST:PORT, try again.\n\n'
  done
  addr="$typed"
  if [ "$addr" = "$server" ]; then rm -f "$ovr"; else printf '%s' "$addr" > "$ovr"; fi

  printf '\nPassword (press Enter if none):\n> '
  read -r password || password=""

  if [ ! -f "$AP_DIR/$LADX_ROM" ]; then
    printf '\nThe base ROM is missing from the Archipelago folder and was not found under\n%s\nPress Enter to go back.\n' "$BASE_ROM_DIRECTORY"
    read -r _; return 1
  fi
  if [ -f "$ovr" ]; then connect="$addr"; else connect=""; fi     # the patch carries its own address
  if ! start_client "$patch" "$connect" "$password" "$addr" "$name"; then
    printf '\nThe client failed to start. See the log:\n%s\nPress Enter to go back.\n' "$LOG"
    read -r _; return 1
  fi
  screen_started "$name" "Patching the ROM first. This can take a while."
  return 0
}

solo_flow() {
  yaml="$1"; name=$(name_of "$yaml")
  if [ ! -f "$AP_DIR/$LADX_ROM" ]; then
    clear_screen
    printf 'AP LADX - Solo: %s\n\nThe base ROM is missing from the Archipelago folder and was not found under\n%s\nPress Enter to go back.\n' "$name" "$BASE_ROM_DIRECTORY"
    read -r _; return 1
  fi
  command -v setsid >/dev/null 2>&1 || return 1
  : > "$LOG"; rm -f "$SOLO_STATUS"
  setsid sh "$APP_DIR/ap.sh" _solo "$yaml" >>"$LOG" 2>&1 </dev/null &
  sleep 1
  clear_screen
  printf 'AP LADX - Solo: %s\n\n' "$name"
  printf '%s\n\n' "$(status_text generating)"
  printf 'Press enter to exit at any time. Exiting before\nit finishes stops the generation.\n'
  read_with_status 4 solo_status
  solo_stop
  return 0
}

# choose <title> <back word> <allow option 8: 1|0> <file list> <hint when empty>
# returns 0 and sets $picked, 1 = quit/back, 2 = option 8 (generate solo game)
choose() {
  title="$1"; backword="$2"; allow8="$3"; list="$4"; hint="$5"; page=0
  count=$(printf '%s' "$list" | grep -c .)
  pages=$(( (count + PAGE_SIZE - 1) / PAGE_SIZE )); [ "$pages" -lt 1 ] && pages=1
  while :; do
    first=$(( page * PAGE_SIZE + 1 ))
    clear_screen
    printf 'AP LADX\n'
    [ -n "$note" ] && { printf '%s\n' "$note"; note=""; }
    printf '\n%s' "$title"
    [ "$pages" -gt 1 ] && printf ' (page %d of %d)' $((page + 1)) "$pages"
    printf ':\n'
    if [ "$count" -eq 0 ]; then
      printf ' %s\n' "$hint"
    else
      printf '%s\n' "$list" | sed -n "${first},$((first + PAGE_SIZE - 1))p" | {
        n=0
        while IFS= read -r f; do
          n=$((n + 1))
          printf ' %d) %s\n' "$n" "$(name_of "$f")"
        done
      }
    fi
    if [ "$page" -gt 0 ] && [ $((page + 1)) -lt "$pages" ]; then printf ' 6) Previous Page | 7) Next Page\n'
    elif [ "$page" -gt 0 ]; then printf ' 6) Previous Page\n'
    elif [ $((page + 1)) -lt "$pages" ]; then printf ' 7) Next Page\n'; fi
    [ "$allow8" = 1 ] && printf ' 8) Generate solo game\n'
    printf '\nEnter a number, or just press Enter to %s.\n> ' "$backword"
    read -r choice || return 1
    case "$choice" in
      "") return 1 ;;
      6) [ "$page" -gt 0 ] && page=$((page - 1)) ;;
      7) [ $((page + 1)) -lt "$pages" ] && page=$((page + 1)) ;;
      8) [ "$allow8" = 1 ] && return 2 ;;
      [1-5])
        k=$((first + choice - 1))
        if [ "$k" -le "$count" ]; then
          picked=$(printf '%s\n' "$list" | sed -n "${k}p")
          return 0
        fi ;;
    esac
  done
}

menu() {
  [ -f "$END_FILE" ] && { note="Last client session: $(cat "$END_FILE")"; rm -f "$END_FILE"; }
  while :; do
    list=$(list_files "$PATCH_DIR" apladx apladxb)
    choose "Select a patch" quit 1 "$list" "No patches found. Put .apladx/.apladxb files in: $PATCH_DIR"
    case $? in
      0) select_patch "$picked" && return ;;
      2) solo_menu && return ;;
      *) return ;;
    esac
  done
}

# returns 0 once a solo game was run, 1 to go back to the main menu
solo_menu() {
  while :; do
    list=$(list_files "$SOLO_DIR" yaml yml)
    choose "Select a yaml for the solo game" "go back" 0 "$list" "No yamls found. Put .yaml files in: $SOLO_DIR" || return 1
    solo_flow "$picked" && return 0
  done
}

do_ui() {
  solo_stop                                  # never leave a stale generation running
  if is_running; then screen_running; return; fi
  setup
  if [ ! -x "$LAUNCHER" ]; then
    clear_screen
    printf 'AP LADX\n\nArchipelago is not installed. Put the Archipelago .tar.gz in:\n%s\nand run AP LADX again.\n\nPress Enter to quit.\n' "$APP_DIR"
    read -r _; return
  fi
  menu
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
  status) status_text "$(client_status)" ;;
  stop)   do_stop ;;
  log)    tail -n 50 "$LOG" ;;
  *)      echo "usage: $0 [ui | status | stop | log]"; exit 1 ;;
esac
