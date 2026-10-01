#!/bin/sh
# Stand-in for `java -jar <validator> -i <zip> -o <dir> --skip_validator_update`.
#
# Tests configure this script as the Java executable and put the behaviour where
# the jar path would go, so the arguments arrive as
#   $1=-jar $2=<mode> $3=-i $4=<zip> $5=-o $6=<output dir> $7=--skip_validator_update
#
# The script first records its own PID in <output dir>/fake.pid, then exits 65 if
# the last argument is missing. A mode written as <mode>@<path> also copies the
# input ZIP to <path>, so a test can inspect what the validator was given. Modes:
#   sleep       replace this shell with `sleep 30`, so the recorded PID is the
#               process that a deadline or cancel must kill
#   big_output  write 200 KiB (25,600 lines of "%07d\n") and exit 3
#   report      write a well-formed, empty report.json and exit 0
#   big_report  write a sparse report.json of 64 MiB + 1 byte and exit 0
#   bad_report  write a truncated report.json and exit 0
mode="$2"
zip="$4"
out="$6"

echo "$$" > "$out/fake.pid"

if [ "$7" != "--skip_validator_update" ]; then
  echo "missing --skip_validator_update" >&2
  exit 65
fi

case "$mode" in
  *@*)
    cp "$zip" "${mode#*@}"
    mode="${mode%%@*}"
    ;;
esac

case "$mode" in
  sleep)
    exec sleep 30
    ;;
  big_output)
    awk 'BEGIN { for (i = 0; i < 25600; i++) printf "%07d\n", i }'
    exit 3
    ;;
  report)
    printf '{"summary":{"validatorVersion":"fake"},"notices":[]}' > "$out/report.json"
    ;;
  big_report)
    dd if=/dev/null of="$out/report.json" bs=1 seek=67108865 count=0 2>/dev/null
    ;;
  bad_report)
    printf '{"notices": [' > "$out/report.json"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 64
    ;;
esac
