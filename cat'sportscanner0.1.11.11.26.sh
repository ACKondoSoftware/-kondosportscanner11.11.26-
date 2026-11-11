#!/usr/bin/env bash
# cat's port scanner v0.1
# 100% vibe coded, 100% single file, 100% no dependencies beyond bash + /dev/tcp
# AC Kondo Software — est. 1999 (in spirit) — meow meow me :3

set -u

VERSION="0.1"
NAME="cat's port scanner"

HOST=""
PORTS=""
TIMEOUT=1
OPEN_ONLY=1
THREADS=64

usage() {
    cat <<EOF
$NAME v$VERSION

Usage: $0 -h <host> [-p <ports>] [-t <timeout>] [-a] [-j <threads>]

  -h <host>     target host or IP (required)
  -p <ports>    port spec: 80,443,1-1024,22,8000-8100 (default: 1-1024)
  -t <timeout>  per-port timeout in seconds (default: 1)
  -a            show ALL ports, not just open ones
  -j <threads>  parallel workers (default: 64)
  -v            version
  -?            this help

Examples:
  $0 -h 192.168.1.1
  $0 -h example.com -p 22,80,443,8000-8100
  $0 -h 10.0.0.5 -p 1-65535 -j 256 -t 0.5

Note: uses bash's /dev/tcp — no nc, no nmap, no python. just vibes.
EOF
}

die() { echo "cat: $*" >&2; exit 1; }

parse_ports() {
    local spec="$1"
    local out=()
    IFS=',' read -ra chunks <<< "$spec"
    for chunk in "${chunks[@]}"; do
        chunk="${chunk//[[:space:]]/}"
        [[ -z "$chunk" ]] && continue
        if [[ "$chunk" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local lo="${BASH_REMATCH[1]}"
            local hi="${BASH_REMATCH[2]}"
            (( lo < 1 || hi > 65535 || lo > hi )) && die "bad range: $chunk"
            for ((p=lo; p<=hi; p++)); do out+=("$p"); done
        elif [[ "$chunk" =~ ^[0-9]+$ ]]; then
            (( chunk < 1 || chunk > 65535 )) && die "bad port: $chunk"
            out+=("$chunk")
        else
            die "bad port spec: $chunk"
        fi
    done
    printf '%s\n' "${out[@]}" | sort -n -u
}

probe() {
    local host="$1" port="$2" timeout="$3"
    # bash /dev/tcp, timeout via read from a subshell
    if ( exec 3<>"/dev/tcp/$host/$port" ) 2>/dev/null; then
        return 0
    fi
    return 1
}

probe_timed() {
    local host="$1" port="$2" timeout="$3"
    local rc=1
    # run probe in background, kill after timeout
    (
        if ( exec 3<>"/dev/tcp/$host/$port" ) 2>/dev/null; then
            exec 3<&-
            exec 3>&-
            exit 0
        fi
        exit 1
    ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.05
        waited=$((waited + 1))
        if (( waited > timeout * 20 )); then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 1
        fi
    done
    wait "$pid"
    rc=$?
    return $rc
}

main() {
    while getopts ":h:p:t:aj:v?" opt; do
        case "$opt" in
            h) HOST="$OPTARG" ;;
            p) PORTS="$OPTARG" ;;
            t) TIMEOUT="$OPTARG" ;;
            a) OPEN_ONLY=0 ;;
            j) THREADS="$OPTARG" ;;
            v) echo "$NAME v$VERSION"; exit 0 ;;
            \?) usage; exit 0 ;;
            :) die "option -$OPTARG needs an argument" ;;
        esac
    done

    [[ -z "$HOST" ]] && { usage; die "no host given"; }
    [[ -z "$PORTS" ]] && PORTS="1-1024"

    command -v bash >/dev/null 2>&1 || die "bash not found"

    echo "$NAME v$VERSION"
    echo "target:  $HOST"
    echo "ports:   $PORTS"
    echo "timeout: ${TIMEOUT}s"
    echo "workers: $THREADS"
    echo "---"

    local -a port_list
    mapfile -t port_list < <(parse_ports "$PORTS")
    local total="${#port_list[@]}"
    local found=0

    # simple worker pool: chunk the port list across N background procs
    local chunk=$(( (total + THREADS - 1) / THREADS ))
    (( chunk < 1 )) && chunk=1

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    local i=0
    local w=0
    while (( i < total )); do
        local slice=("${port_list[@]:i:chunk}")
        (
            for p in "${slice[@]}"; do
                if probe_timed "$HOST" "$p" "$TIMEOUT"; then
                    echo "open $p"
                fi
            done
        ) > "$tmpdir/worker.$w" 2>/dev/null &
        w=$((w + 1))
        i=$((i + chunk))
    done
    wait

    # aggregate
    cat "$tmpdir"/worker.* 2>/dev/null | sort -k2 -n | while read -r state port; do
        if [[ "$state" == "open" ]]; then
            echo "[+] $port/tcp open"
            found=$((found + 1))
        elif (( OPEN_ONLY == 0 )); then
            echo "[-] $port/tcp closed"
        fi
    done

    echo "---"
    echo "meow meow me :3"
}

main "$@"