#!/bin/bash

#   --custom-mode 2560x1810@120Hz \
wlr-randr \
  --output moreland \
  --custom-mode 3392x2400@120Hz \
  --pos 6002,0

if ! pgrep -x moreland >/dev/null; then
    nohup moreland --fps 120 --position 6002 --show-cursor \
        >/dev/null 2>&1 &
fi
