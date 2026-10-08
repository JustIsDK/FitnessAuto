#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
magick -size 1024x1024 'xc:#102631' \
  -fill none -stroke '#F2F8F7' -strokewidth 47 \
  -draw "path 'M 195,639 L 720,639 L 795,723 L 272,723 Z'" \
  -draw "line 698,632 768,335" \
  -draw "line 659,330 835,330" \
  -draw "line 735,450 839,450" \
  -draw "line 292,741 249,741" \
  -draw "line 770,741 818,741" \
  -stroke '#48D7BD' -strokewidth 24 \
  -draw "line 313,670 670,670" \
  -alpha off \
  TreadmillFTMSProbe/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
