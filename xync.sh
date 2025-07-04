#!/usr/bin/env sh
## xync.sh
set -eu ## fail on errors and undefined variables

# check pipefail in a subshell and set if supported
# shellcheck disable=SC3040
(set -o pipefail 2> /dev/null) && set -o pipefail

## set self identification values
readonly SCRIPT="${0##*/}"
readonly SCRIPT_PATH="${0%/*}"

## set date substitutions for macros
__DOW=$(date "+%a")
readonly __DOW
__DOM=$(date "+%d")
readonly __DOM
__MOY=$(date "+%m")
readonly __MOY
__CYR=$(date "+%Y")
readonly __CYR
__NOW=$(date "+%s")
readonly __NOW

## init configuration with values from environment or set defaults
REPLICATE_SETS=${REPLICATE_SETS:-""} ## default empty
ALLOW_ROOT_DATASETS="${ALLOW_ROOT_DATASETS:-0}"
ALLOW_RECONCILIATION="${ALLOW_RECONCILIATION:-0}"
RECURSE_CHILDREN="${RECURSE_CHILDREN:-0}"
SNAP_PATTERN="${SNAP_PATTERN:-"@autorep-"}"
SNAP_KEEP="${SNAP_KEEP:-2}"
SYSLOG="${SYSLOG:-1}"
SYSLOG_FACILITY="${SYSLOG_FACILITY:-"user"}"
TAG="${TAG:-"%MOY%%DOM%%CYR%_%NOW%"}"
LOG_FILE="${LOG_FILE:-"autorep-%TAG%.log"}"
LOG_KEEP="${LOG_KEEP:-5}"
LOG_BASE=${LOG_BASE:-""} ## default empty
LOGGER="${LOGGER:-$(which logger || true)}"
FIND="${FIND:-$(which find || true)}"
SSH="${SSH:-$(which ssh || true)}"
ZFS="${ZFS:-$(which zfs || true)}"
ZFS_INCR_OPT="${ZFS_INCR_OPT:-"-I"}"
ZFS_SEND_OPTS="${ZFS_SEND_OPTS:-"-p"}"
ZFS_RECV_OPTS="${ZFS_RECV_OPTS:-"-vF"}"
HOST_CHECK="${HOST_CHECK:-"ping -c1 -q -W2 %HOST%"}"
## temp path used for lock files
TMPDIR="${TMPDIR:-"/tmp"}"
## temp file to store dataset list
DATASETS=$(mktemp)
SRC_SNAPS=$(mktemp)
DST_SNAPS=$(mktemp)
## init values used in snapCreate and exitClean
__PAIR_COUNT=0
__PAIR_SKIP_COUNT=0
__DATASET_COUNT=0
__DATASET_SKIP_COUNT=0

## output log files in decreasing age order
sortLogs() {
  ## check if file logging is enabled
  if [ -z "$LOG_BASE" ] || [ ! -d "$LOG_BASE" ]; then
    return 0
  fi
  ## find existing logs
  logs=$($FIND "$LOG_BASE" -maxdepth 1 -type f -name 'autorep-*')
  ## get file change time via stat (platform specific)
  if [ "$(uname -s)" = "Linux" ] || [ "$(uname -s)" = "SunOS" ]; then
    fstat='stat -c %Z'
  else
    fstat='stat -f %c'
  fi
  ## output logs in descending age order
  for log in $logs; do
    printf "%s\t%s\n" "$($fstat "$log")" "$log"
  done | sort -rn | cut -f2
}

## check log count and delete old logs
pruneLogs() {
  logs=$(sortLogs)
  logCount=0
  if [ -n "$logs" ]; then
    logCount=$(printf "%s" "$logs" | wc -l)
  fi
  if [ "$logCount" -gt "$LOG_KEEP" ]; then
    prune="$(printf "%s\n" "$logs" | sed -n "$((LOG_KEEP + 1)),\$p")"
    printf "pruning %d logs\n" "$((logCount - LOG_KEEP + 1))" 1>&2
    printf "%s\n" "$prune" | xargs rm -vf
  fi
}

## delete lock files
clearLock() {
  lockFile=$1
  if [ -f "$lockFile" ]; then
    printf "deleting lockfile %s\n" "$lockFile" 1>&2
    rm "$lockFile"
  fi
}

## exit and cleanup
exitClean() {
  exitCode=${1:-0}
  extraMsg=${2:-""}
  status="SUCCESS"
  ## set status to warning if we skipped any datasets
  if [ "$__PAIR_SKIP_COUNT" -gt 0 ] || [ "$__DATASET_SKIP_COUNT" -gt 0 ]; then
    status="WARNING"
  fi
  logMsg=$(printf "%s: total sets=%d skipped=%d total datasets=%d skipped=%d" "$status" "$__PAIR_COUNT" "$__PAIR_SKIP_COUNT" "$__DATASET_COUNT" "$__DATASET_SKIP_COUNT")
  ## build and print error message
  if [ "$exitCode" -ne 0 ]; then
    status="ERROR"
    logMsg=$(printf "%s: operation exited unexpectedly: code=%d" "$status" "$exitCode")
    if [ -n "$extraMsg" ]; then
      logMsg=$(printf "%s msg=%s" "$logMsg" "$extraMsg")
    fi
  fi
  ## append extra message if available
  if [ "$exitCode" -eq 0 ] && [ -n "$extraMsg" ]; then
    logMsg=$(printf "%s: %s" "$logMsg" "$extraMsg")
  fi
  ## cleanup old logs and clear locks
  pruneLogs
  clearLock "${TMPDIR}/.replicate.snapshot.lock"
  clearLock "${TMPDIR}/.replicate.send.lock"
  ## remove DATASETS tmp file
  rm "$DATASETS" "$SRC_SNAPS" "$DST_SNAPS"
  ## print log message and exit
  printf "%s\n" "$logMsg" 1>&2
  exit "$exitCode"
}

## lockfile creation and maintenance
checkLock() {
  lockFile=$1
  ## check our lockfile status
  if [ -f "$lockFile" ]; then
    ## see if this pid is still running
    if ps -p "$(cat "$lockFile")" > /dev/null 2>&1; then
      ## looks like it's still running
      printf "ERROR: script is already running as: %d\n" "$(cat "$lockFile")" 1>&2
    else
      ## stale lock file?
      printf "ERROR: stale lockfile %s\n" "$lockFile" 1>&2
    fi
    ## cleanup and exit
    exitClean 128 "confirm script is not running and delete lockfile $lockFile"
  fi
  ## well no lockfile..let's make a new one
  printf "creating lockfile %s\n" "$lockFile" 1>&2
  printf "%d\n" "$$" > "$lockFile"
}

## check remote host status
checkHost() {
  ## do we have a host check defined
  if [ -z "$HOST_CHECK" ]; then
    return 0
  fi
  host=$1
  if [ -z "$host" ]; then
    return 0
  fi
  cmd=$(printf "%s\n" "$HOST_CHECK" | sed "s/%HOST%/$host/g")
  printf "checking host cmd=%s\n" "$cmd" 2>&1
  ## run the check
  if ! $cmd > /dev/null 2>&1; then
    return 1
  fi
  return 0
}

getDatasets() {
  set=$1
  host=$2
  cmd=""
  ## build command
  if [ -n "$host" ]; then
    $SSH $host "$ZFS list -Hr -o name \"$set\"" || return 1
  else
    $ZFS list -Hr -o name "$set" || return 1
  fi
}

createDataset() {
  set=$(dirname "$1")
  host=$2
  printf "creating destination dataset: %s\n" "$set" 1>&2
  ## build command
  if [ -n "$host" ]; then
    $SSH $host "$ZFS create -p \"$set\"" || return 1
  else
    $ZFS create -p "$set" || return 1
  fi
}

## ensure dataset exists
checkDataset() {
  set=$1
  host=$2
  printf "checking dataset: %s\n" "$set" 1>&2
  ## build command
  if [ -n "$host" ]; then
    $SSH $host "$ZFS list -H -o name \"$set\"" || return 1
  else
    $ZFS list -H -o name "$set" || return 1
  fi
}

## small wrapper around zfs destroy
snapDestroy() {
  snap=$1
  host=$2
  printf "destroying snapshot: %s\n" "$snap" 1>&2
  if [ -n "$host" ]; then
    $SSH $host "$ZFS destroy \"$snap\"" || true
  else
    $ZFS destroy "$snap" || true
  fi
}

## main replication function
snapSend() {
  base=$1
  snap=$2
  src=$3
  srcHost=$4
  dst=$5
  dstHost=$6
  printf "sending snapshot: %s\n" "$snap" 1>&2
  ## check our send lockfile
  checkLock "${TMPDIR}/.replicate.send.lock"
  if [ -n "$srcHost" ]; then
    if [ -n "$base" ]; then
      if ! $SSH $srcHost "$ZFS send $ZFS_SEND_OPTS $ZFS_INCR_OPT \"$base\" \"$src@$snap\"" | $ZFS receive $ZFS_RECV_OPTS "$dst"; then
        snapDestroy "${src}@${name}" "$srcHost"
        printf "WARNING: failed to send snapshot: %s\n" "${src}@${name}" 1>&2
        __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      fi
    else
      if ! $SSH $srcHost "$ZFS send $ZFS_SEND_OPTS \"$src@$snap\"" | $ZFS receive $ZFS_RECV_OPTS "$dst"; then
        snapDestroy "${src}@${name}" "$srcHost"
        printf "WARNING: failed to send snapshot: %s\n" "${src}@${name}" 1>&2
        __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      fi
    fi
  elif [ -n "$dstHost" ]; then
    if [ -n "$base" ]; then
      if ! $ZFS send $ZFS_SEND_OPTS $ZFS_INCR_OPT "$base" "$src@$snap" | $SSH $dstHost "$ZFS receive $ZFS_RECV_OPTS \"$dst\""; then
        snapDestroy "${src}@${name}" "$srcHost"
        printf "WARNING: failed to send snapshot: %s\n" "${src}@${name}" 1>&2
        __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      fi
    else
      if ! $ZFS send $ZFS_SEND_OPTS "$src@$snap" | $SSH $dstHost "$ZFS receive $ZFS_RECV_OPTS \"$dst\""; then
        snapDestroy "${src}@${name}" "$srcHost"
        printf "WARNING: failed to send snapshot: %s\n" "${src}@${name}" 1>&2
        __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      fi
    fi
  elif [ -z "$srcHost" ] && [ -z "$dstHost" ]; then
    if [ -n "$base" ]; then
      if ! $ZFS send $ZFS_SEND_OPTS $ZFS_INCR_OPT "$base" "$src@$snap" | $ZFS receive $ZFS_RECV_OPTS "$dst"; then 
        snapDestroy "${src}@${name}" "$srcHost"
        printf "WARNING: failed to send snapshot: %s\n" "${src}@${name}" 1>&2
        __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      fi
    else
      if ! $ZFS send $ZFS_SEND_OPTS "$src@$snap" | $ZFS receive $ZFS_RECV_OPTS "$dst"; then
        snapDestroy "${src}@${name}" "$srcHost"
        printf "WARNING: failed to send snapshot: %s\n" "${src}@${name}" 1>&2
        __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      fi
    fi
  fi
  ## clear lockfile
  clearLock "${TMPDIR}/.replicate.send.lock"
}

## list replication snapshots
snapList() {
  set=$1
  host=$2
  pattern=$3
  printf "listing snapshots for set: %s\n" "$set" 1>&2
  ## build send command
  if [ -n "$host" ]; then
    snaps=$($SSH $host "$ZFS list -H -o name -s creation -t snapshot \"$set\"") || true
  else
    snaps=$($ZFS list -H -o name -s creation -t snapshot "$set") || true
  fi
  if [ -n "$pattern" ]; then
    printf "%s\n" "$snaps" | grep "$pattern" || true
  else
    printf "%s\n" "$snaps" || true
  fi
}

## create source snapshots
snapCreate() {
  name=$1
  set=$2
  host=$3
  printf "creating snapshot: %s\n" "${set}@${name}" 1>&2
  if [ -n "$host" ]; then
    if ! $SSH $host "$ZFS snapshot \"${set}@${name}\""; then
      snapDestroy "${set}@${name}" "$host"
      printf "WARNING: failed to create snapshot: %s\n" "${set}@${name}" 1>&2
      __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      continue
    fi
  else
    if ! $ZFS snapshot "${src}@${name}"; then
      snapDestroy "${src}@${name}" "$srcHost"
      printf "WARNING: failed to create snapshot: %s\n" "${set}@${name}" 1>&2
      __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
      continue
    fi
  fi
}

## central function
snapInit() {
  ## make sure we aren't ever creating simultaneous snapshots
  checkLock "${TMPDIR}/.replicate.snapshot.lock"
  ## set our snap name
  name="autorep-${TAG}"
  ## generate snapshot list and cleanup old snapshots
  for pair in $REPLICATE_SETS; do
    __PAIR_COUNT=$((__PAIR_COUNT + 1))
    ## split dataset into source and destination parts and trim any trailing space
    src=$(printf "%s\n" "$pair" | cut -f1 -d: | sed 's/[[:space:]]*$//')
    dst=$(printf "%s\n" "$pair" | cut -f2 -d: | sed 's/[[:space:]]*$//')
    ## check for root dataset destination
    if [ "$ALLOW_ROOT_DATASETS" -ne 1 ]; then
      if [ "$dst" = "$(basename "$dst")" ] || [ "$dst" = "$(basename "$dst")/" ]; then
        temps="replicating root datasets can lead to data loss - set ALLOW_ROOT_DATASETS=1 to override"
        printf "WARNING: skipping replication set '%s' - %s\n" "$pair" "$temps" 1>&2
        __PAIR_SKIP_COUNT=$((__PAIR_SKIP_COUNT + 1))
        continue
      fi
    fi
    ## init source and destination host in each loop iteration
    srcHost=""
    dstHost=""
    ## look for source host option
    if [ "${src#*"@"}" != "$src" ]; then
      srcHost=$(printf "%s\n" "$src" | cut -f2 -d@)
      src=$(printf "%s\n" "$src" | cut -f1 -d@)
    fi
    ## look for destination host option
    if [ "${dst#*"@"}" != "$dst" ]; then
      dstHost=$(printf "%s\n" "$dst" | cut -f2 -d@)
      dst=$(printf "%s\n" "$dst" | cut -f1 -d@)
    fi
    ## check source and destination hosts
    if ! checkHost "$srcHost" || ! checkHost "$dstHost"; then
      printf "WARNING: skipping replication set '%s' - source or destination host check failed\n" "$pair" 1>&2
      __PAIR_SKIP_COUNT=$((__PAIR_SKIP_COUNT + 1))
      continue
    fi
    ## check source and destination datasets
    if ! checkDataset "$src" "$srcHost" || ! checkDataset "$dst" "$dstHost"; then
      printf "WARNING: skipping replication set '%s' - source or destination dataset check failed\n" "$pair" 1>&2
      __PAIR_SKIP_COUNT=$((__PAIR_SKIP_COUNT + 1))
      continue
    fi
    ## replicate all child datasets if RECURSE_CHILDREN=1
    if [ "$RECURSE_CHILDREN" -eq 1 ]; then
      getDatasets "$src" "$srcHost" > "$DATASETS"
    else
      echo "$src" > "$DATASETS"
    fi
    ## set main destination dataset
    ## needed so we dont add $dst on top of itself
    _dst="$dst"
    ## replicate each dataset separately
    exec 5< "$DATASETS"
    while read -r dataset <&5; do
      __DATASET_COUNT=$((__DATASET_COUNT + 1))
      ## set scr and dst datasets
      src="$dataset"
      dst="$_dst/$src"
      ## verify dataset exists on destination
      ## if not, create it
      checkDataset "$dst" "$dstHost" || createDataset "$dst" "$dstHost"
      ## get source and destination snapshots
      srcSnaps=$(snapList "$src" "$srcHost" "$SNAP_PATTERN")
      dstSnaps=$(snapList "$dst" "$dstHost" "$SNAP_PATTERN")
      # Need a tmp file to not run in subshell
      echo "$srcSnaps" | sort -r > "$SRC_SNAPS"
      echo "$dstSnaps" > "$DST_SNAPS"
      while read -r snap; do
        ## while we are here...check for our current snap name
        if [ "$snap" = "${src}@${name}" ]; then
          ## looks like it's here...we better kill it
          printf "destroying duplicate snapshot: %s@%s\n" "$src" "$name" 1>&2
          snapDestroy "${src}@${name}" "$srcHost"
        fi
      done < "$SRC_SNAPS"
      ## get source and destination snap count
      srcSnapCount=0
      dstSnapCount=0
      if [ -n "$srcSnaps" ]; then
        srcSnapCount=$(printf "%s\n" "$srcSnaps" | wc -l)
      fi
      if [ -n "$dstSnaps" ]; then
        dstSnapCount=$(printf "%s\n" "$dstSnaps" | wc -l)
      fi
      ## set our base snap for incremental generation if src contains a sufficient
      ## number of snapshots and the base source snapshot exists in destination dataset
      base=""
      if [ "$srcSnapCount" -ge 1 ] && [ "$dstSnapCount" -ge 1 ]; then
        while read -r ss; do
          ## get source snapshot name
          sn=$(printf "%s\n" "$ss" | cut -f2 -d@)
          ## loop over destinations snaps and look for a match
          while read -r ds; do
            dn=$(printf "%s\n" "$ds" | cut -f2 -d@)
            if [ "$dn" = "$sn" ]; then
              base="$ss"
              break 2
            fi
          done < "$DST_SNAPS"
        done < "$SRC_SNAPS"
        ## no matching base, are we allowed to fallback?
        if [ -z "$base" ] && [ "$ALLOW_RECONCILIATION" -ne 1 ]; then
          temps=$(printf "source snapshot '%s' not in destination dataset: %s" "$ss" "$dst")
          temps=$(printf "%s - set 'ALLOW_RECONCILIATION=1' to fallback to a full send" "$temps")
          printf "WARNING: skipping dataset '%s' - %s\n" "$dataset" "$temps" 1>&2
          __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
          continue
        fi
      fi
      ## without a base snapshot, the destination must be clean
      if [ -z "$base" ] && [ "$dstSnapCount" -gt 0 ]; then
        ## allowed to prune remote dataset?
        if [ "$ALLOW_RECONCILIATION" -ne 1 ]; then
          temps="destination contains snapshots not in source - set 'ALLOW_RECONCILIATION=1' to prune snapshots"
          printf "WARNING: skipping dataset '%s' - %s\n" "$dataset" "$temps" 1>&2
          __DATASET_SKIP_COUNT=$((__DATASET_SKIP_COUNT + 1))
          continue
        fi
        ## prune destination snapshots
        dstSnapsAll=$(snapList "$dst" "$dstHost" "")
        printf "pruning destination snapshots: %s\n" "$dstSnapsAll" 1>&2
        ## prune ALL snaps on destination
        printf "%s\n" "$dstSnapsAll" | while read -r snap; do
          snapDestroy "$snap" "$dstHost"
        done
      fi
      ## cleanup old snapshots
      if [ "$srcSnapCount" -ge "$SNAP_KEEP" ]; then
        ## snaps are sorted above by creation in ascending order
        printf "%s\n" "$srcSnaps" | sed -n "1,$((srcSnapCount - SNAP_KEEP))p" | while read -r snap; do
          printf "found old snapshot %s\n" "$snap" 1>&2
          snapDestroy "$snap" "$srcHost"
        done
      fi
      if [ "$dstSnapCount" -ge "$SNAP_KEEP" ]; then
        ## snaps are sorted above by creation in ascending order
        printf "%s\n" "$dstSnaps" | sed -n "1,$((dstSnapCount - SNAP_KEEP))p" | while read -r snap; do
          printf "found old snapshot %s\n" "$snap" 1>&2
          snapDestroy "$snap" "$dstHost"
        done
      fi
      ## create source snapshot
      snapCreate "$name" "$src" "$srcHost"
      ## send snapshot to destination
      snapSend "$base" "$name" "$src" "$srcHost" "$dst" "$dstHost"
    done < "$DATASETS"
    exec 9<&-
  done
  ## clear snapshot lockfile
  clearLock "${TMPDIR}/.replicate.snapshot.lock"
}

## handle logging to file or syslog
writeLog() {
  line=$1
  logf="/dev/null"
  ## if a log base and file has been configured set them
  if [ -n "$LOG_BASE" ] && [ -n "$LOG_FILE" ]; then
    logf="${LOG_BASE}/${LOG_FILE}"
  fi
  ## always print to stdout and copy to logfile if set
  printf "%s %s[%d]: %s\n" "$(date '+%b %d %T')" "$SCRIPT" "$$" "$line" | tee -a "$logf" 1>&2
  ## if syslog has been enabled write to syslog via logger
  if [ "$SYSLOG" -eq 1 ] && [ -n "$LOGGER" ]; then
    $LOGGER -p "${SYSLOG_FACILITY}.info" -t "$SCRIPT" "$line"
  fi
}

## read from stdin till script exit
captureOutput() {
  while IFS= read -r line; do
    writeLog "$line"
  done
}

## perform macro substitution for tags
subTags() {
  m=$1
  ## do the substitutions
  m=$(printf "%s\n" "$m" | sed "s/%DOW%/${__DOW}/g")
  m=$(printf "%s\n" "$m" | sed "s/%DOM%/${__DOM}/g")
  m=$(printf "%s\n" "$m" | sed "s/%MOY%/${__MOY}/g")
  m=$(printf "%s\n" "$m" | sed "s/%CYR%/${__CYR}/g")
  m=$(printf "%s\n" "$m" | sed "s/%NOW%/${__NOW}/g")
  m=$(printf "%s\n" "$m" | sed "s/%TAG%/${TAG}/g")
  printf "%s\n" "$m"
}

## show last replication status
showStatus() {
  log=$(sortLogs | head -n 1)
  if [ -n "$log" ]; then
    printf "%s\n" "$(cat "${log}" | tail -n 1)" && exit 0
  fi
  ## not found, log error and exit
  writeLog "ERROR: unable to find most recent log file, cannot print status" && exit 1
}

## show usage and exit
showHelp() {
  printf "Usage: %s [config] [options]\n\n" "${SCRIPT}"
  printf "POSIX shell script to automate ZFS Replication\n\n"
  printf "Options:\n"
  printf "  -c, --config <configFile>    configuration file\n"
  printf "  -s, --status                 print most recent log messages to stdout\n"
  printf "  -h, --help                   show this message\n"
  exit 0
}

## read config file if present, process flags, validate, and lock config variables
loadConfig() {
  configFile=""
  status=0
  help=0
  ## sub macros for logging
  TAG="$(subTags "$TAG")"
  LOG_FILE="$(subTags "$LOG_FILE")"
  ## check for config file as first argument for backwards compatibility
  if [ $# -gt 0 ] && [ -f "$1" ]; then
    configFile="$1"
    shift
  fi
  ## process command-line options
  while [ $# -gt 0 ]; do
    if [ "$1" = "-c" ] || [ "$1" = "--config" ]; then
      shift
      configFile="$1"
      shift
      continue
    fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
      help=1
      shift
      continue
    fi
    if [ "$1" = "-s" ] || [ "$1" = "--status" ]; then
      status=1
      shift
      continue
    fi
    ## unknown option
    writeLog "ERROR: illegal option ${1}" && exit 1
  done
  ## someone ask for help?
  if [ "$help" -eq 1 ]; then
    showHelp
  fi
  ## attempt to load configuration
  if [ -f "$configFile" ]; then
    # shellcheck disable=SC1090
    . "$configFile"
  elif configFile="${SCRIPT_PATH}/config.sh" && [ -f "$configFile" ]; then
    # shellcheck disable=SC1090
    . "$configFile"
  fi
  ## perform final substitution
  TAG="$(subTags "$TAG")"
  LOG_FILE="$(subTags "$LOG_FILE")"
  ## lock configuration
  readonly REPLICATE_SETS
  readonly ALLOW_ROOT_DATASETS
  readonly ALLOW_RECONCILIATION
  readonly RECURSE_CHILDREN
  readonly SNAP_PATTERN
  readonly SNAP_KEEP
  readonly SYSLOG
  readonly SYSLOG_FACILITY
  readonly TAG
  readonly LOG_FILE
  readonly LOG_KEEP
  readonly LOG_BASE
  readonly LOGGER
  readonly FIND
  readonly SSH
  readonly ZFS
  readonly ZFS_SEND_OPTS
  readonly ZFS_RECV_OPTS
  readonly HOST_CHECK
  readonly TMPDIR
  ## check configuration
  if [ -n "$LOG_BASE" ] && [ ! -d "$LOG_BASE" ]; then
    mkdir -p "$LOG_BASE"
  fi
  ## we have all we need for status
  if [ "$status" -eq 1 ]; then
    showStatus
  fi
  ## continue validating config
  if [ "$SYSLOG" -eq 1 ] && [ -z "$LOGGER" ]; then
    writeLog "ERROR: unable to locate system logger binary and SYSLOG is enabled" && exit 1
  fi
  if [ -z "$REPLICATE_SETS" ]; then
    writeLog "ERROR: missing required setting REPLICATE_SETS" && exit 1
  fi
  if [ "$SNAP_KEEP" -lt 2 ]; then
    writeLog "ERROR: a minimum of 2 snapshots are required for incremental sending" && exit 1
  fi
  if [ -z "$FIND" ]; then
    writeLog "ERROR: unable to locate system find binary" && exit 1
  fi
  if [ -z "$SSH" ]; then
    writeLog "ERROR: unable to locate system ssh binary" && exit 1
  fi
  if [ -z "$ZFS" ]; then
    writeLog "ERROR: unable to locate system zfs binary" && exit 1
  fi
}

trap  'exitClean 128 "script terminated prematurely"' INT SIGINT SIGTERM SIGQUIT SIGSEGV

## main function, not much here
main() {
  ## do snapshots and send
  snapInit
  ## that's it, sending is called from doSnap
  exitClean 0
}

## process config and start main if we weren't sourced
if [ "$(expr "$SCRIPT" : 'xync')" -gt 0 ]; then
  loadConfig "$@" && main 2>&1 | captureOutput
fi
