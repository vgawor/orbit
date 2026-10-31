#!/bin/zsh
# Prints Orbit widget JSON with the battery level. Uses pmset (built into macOS).
line=$(pmset -g batt | grep -Eo '[0-9]+%;[^;]*;[^)]*' | head -1)
pct=${line%%\%*}
state=$(echo "$line" | cut -d';' -f2 | xargs)
left=$(echo "$line" | cut -d';' -f3 | xargs | cut -d' ' -f1)
[[ -z "$pct" ]] && { echo '{"title":"Battery","value":"No battery","subtitle":"This Mac runs on power."}'; exit 0; }
tint="#34C759"; (( pct < 20 )) && tint="#FF453A"
attention=""; (( pct < 10 )) && [[ "$state" == "discharging" ]] && attention="Battery at $pct%"
printf '{"title":"Battery","value":"%s%%","subtitle":"%s · %s left","progress":%s,"tint":"%s","chip":"%s%%","attention":"%s"}\n' \
  "$pct" "$state" "$left" "$(echo "scale=2; $pct/100" | bc)" "$tint" "$pct" "$attention"
