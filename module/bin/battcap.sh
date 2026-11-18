#!/system/bin/sh
# 魔改电池预设容量 6100mAh (静默) - 参考"电池数据伪装"模块: bind mount 伪造 sysfs / power_profile.xml
# 用法: battcap.sh apply|revert
DATA_DIR=/data/adb/dtbo_oc
FAKE="$DATA_DIR/battfake"
LIST="$DATA_DIR/battcap.mounted"
CAP=6100

is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

umount_one() {
    [ -e "$1" ] || return 0
    is_mounted "$1" || return 0
    umount "$1" 2>/dev/null
}

revert() {
    [ -f "$LIST" ] && while read -r p; do umount_one "$p"; done < "$LIST"
    umount_one /sys/devices/virtual/oplus_chg/battery/battery_fcc
    umount_one /sys/class/oplus_chg/battery/battery_fcc
    umount_one /sys/class/power_supply/battery/charge_full
    umount_one /sys/class/power_supply/battery/charge_full_design
    for p in /odm/etc/power_profile/power_profile.xml /system/etc/power_profile.xml \
             /system_ext/etc/power_profile/power_profile.xml /vendor/etc/power_profile.xml; do
        umount_one "$p"
    done
    rm -f "$LIST"
}

apply_one() { # $1=node path $2=目标值(uAh 或 mAh)
    p="$1"; v="$2"
    [ -e "$p" ] || return 0
    real=$(readlink -f "$p" 2>/dev/null); [ -z "$real" ] && real="$p"
    is_mounted "$real" && return 0
    [ -f "$LIST" ] && grep -qxF "$real" "$LIST" && return 0
    f="$FAKE/$(echo "$real" | tr '/' '_')"
    mkdir -p "$FAKE" 2>/dev/null
    echo "$v" > "$f" 2>/dev/null || return 0
    mount --bind "$f" "$real" 2>/dev/null || return 0
    echo "$real" >> "$LIST"
}

apply_pp() {
    src=""
    for p in /odm/etc/power_profile/power_profile.xml /system/etc/power_profile.xml \
             /system_ext/etc/power_profile/power_profile.xml /vendor/etc/power_profile.xml; do
        [ -f "$p" ] && { src="$p"; break; }
    done
    [ -n "$src" ] || return 0
    real=$(readlink -f "$src" 2>/dev/null); [ -z "$real" ] && real="$src"
    is_mounted "$real" && return 0
    [ -f "$LIST" ] && grep -qxF "$real" "$LIST" && return 0
    mkdir -p "$FAKE" 2>/dev/null
    f="$FAKE/power_profile.xml"
    cat "$real" > "$f" 2>/dev/null || return 0
    sed -i -E 's#(<item name="battery.capacity">)[0-9]+#\16100#' "$f" 2>/dev/null
    grep -q '<item name="battery.capacity">6100<' "$f" 2>/dev/null || return 0
    mount --bind "$f" "$real" 2>/dev/null || return 0
    echo "$real" >> "$LIST"
}

case "$1" in
    apply)
        mkdir -p "$FAKE" 2>/dev/null
        : > "$LIST"
        apply_one /sys/devices/virtual/oplus_chg/battery/battery_fcc 6100
        apply_one /sys/class/oplus_chg/battery/battery_fcc 6100
        apply_one /sys/class/power_supply/battery/charge_full 6100000
        apply_one /sys/class/power_supply/battery/charge_full_design 6100000
        apply_pp
        ;;
    revert) revert ;;
esac
