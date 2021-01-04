#!/bin/dash

tps_is_unlocked() {
    local out
    out="$(gdbus call --system --dest org.boum.tails.PersistentStorage \
           --object-path "/org/boum/tails/PersistentStorage" \
           --method org.freedesktop.DBus.Properties.Get \
           org.boum.tails.PersistentStorage IsUnlocked)"

    if [ "${out}" = "(<true>,)" ]; then
        return 0
    fi
    return 1
}

tps_feature_is_active() {
    local feature="${1}"
    local object_path="/org/boum/tails/PersistentStorage/Features/${feature}"
    local out
    out="$(gdbus call --system --dest org.boum.tails.PersistentStorage \
           --object-path "${object_path}" \
           --method org.freedesktop.DBus.Properties.Get \
           org.boum.tails.PersistentStorage.Feature IsActive)"

    if [ "${out}" = "(<true>,)" ]; then
        return 0
    fi
    return 1
}

tps_activate_feature() {
    # Note: Only tails-persistent-storage and Debian-gdm have the required
    # permissions to call this
    local feature="${1}"
    local object_path="/org/boum/tails/PersistentStorage/Features/${feature}"
    gdbus call --system --dest org.boum.tails.PersistentStorage \
         --object-path "${object_path}" \
         --method org.boum.tails.PersistentStorage.Feature.Activate \
         > /dev/null
}

tps_deactivate_feature() {
    # Note: Only tails-persistent-storage and Debian-gdm have the required
    # permissions to call this
    local feature="${1}"
    local object_path="/org/boum/tails/PersistentStorage/Features/${feature}"
    gdbus call --system --dest org.boum.tails.PersistentStorage \
         --object-path "${object_path}" \
         --method org.boum.tails.PersistentStorage.Feature.Deactivate \
         > /dev/null
}
