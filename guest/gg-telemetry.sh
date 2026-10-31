#!/bin/sh
# Writes a short health line block to the console (the serial port with
# boot-args serial=3) every minute, so a normal boot can be observed without SSH.
while :; do
  {
    echo "GGTEL $(date +%H:%M:%S) $(uptime | sed 's/.*load/load/')"
    ps -Ao %cpu,pid,comm -r | head -8 | sed 's/^/GGTEL   /'
    echo "GGTEL sshd: $(launchctl print system/com.openssh.sshd 2>/dev/null | grep -E 'state =|active count' | tr -s ' \n' ' ')"
    echo "GGTEL net: $(ifconfig en0 2>/dev/null | grep 'inet ' | tr -s ' ') pkts: $(netstat -I en0 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f5,7) listen22: $(netstat -an -p tcp 2>/dev/null | grep -c '\.22 .*LISTEN')"
    echo "GGTEL WindowServer: $(pgrep -x WindowServer | wc -l | tr -d ' ') loginwindow: $(pgrep -x loginwindow | wc -l | tr -d ' ')"
  } > /dev/console 2>&1
  sleep 60
done
