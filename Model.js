.pragma library

// Pure helpers for the omakeyclean panel. No QML types in here so the logic
// stays readable and testable on its own.

// libinput names routinely repeat the vendor ("Razer Razer Huntsman V2",
// "Logitech Logitech USB Receiver"). Collapse an immediately repeated leading
// word so the panel reads like the product on the desk.
function prettyLabel(label) {
    var text = String(label || "").trim()
    if (text === "")
        return "Unknown device"
    var words = text.split(/\s+/)
    if (words.length > 1 && words[0].toLowerCase() === words[1].toLowerCase())
        words.splice(0, 1)
    return words.join(" ")
}

// Nerd Font glyph per device class. Codepoints verified present in
// JetBrainsMono Nerd Font via `fc-list :charset=<cp>`.
function deviceGlyph(kind) {
    if (kind === "keyboard")
        return "󰌌"      // U+F030C nf-md-keyboard
    return "󰴴"          // U+F0D34 nf-md-gesture-tap-button
}

// Devices are stored as a name list; the panel wants fast membership tests.
function selectionSet(names) {
    var set = {}
    var list = names || []
    for (var i = 0; i < list.length; i++)
        set[list[i]] = true
    return set
}

function toggleName(names, name) {
    var list = (names || []).slice()
    var at = list.indexOf(name)
    if (at === -1)
        list.push(name)
    else
        list.splice(at, 1)
    return list
}

// First run, or a device set that changed under us: preselect exactly the
// devices udev calls real keyboards. Auxiliary key-emitters (power buttons,
// headset controls) and the virtual IME keyboard stay off by default.
function defaultKeyboardSelection(keyboards) {
    var picked = []
    var list = keyboards || []
    for (var i = 0; i < list.length; i++)
        if (list[i].class === "keyboard")
            picked.push(list[i].name)
    return picked
}

// Returns "" when arming is safe, otherwise the reason it is blocked.
//
// This release locks keyboards only, which makes the pointer safe by
// construction: the mouse is never disabled, so the unlock button is always
// reachable. If pointer locking is ever added back, it needs its own rule
// keeping at least one pointing device alive.
function armBlocker(keyboardSelection) {
    if ((keyboardSelection || []).length === 0)
        return "Select at least one keyboard to lock."
    return ""
}

function countLabel(count, singular) {
    return count + " " + singular + (count === 1 ? "" : "s")
}

// mm:ss for the auto-unlock countdown.
function formatCountdown(seconds) {
    var total = Math.max(0, Math.round(seconds))
    var mins = Math.floor(total / 60)
    var secs = total % 60
    return mins + ":" + (secs < 10 ? "0" : "") + secs
}

function statusMeta(locked, arming, remaining, autoUnlockSeconds) {
    if (arming && !locked)
        return "Release all keys…"
    if (!locked)
        return "Ready to clean"
    if (autoUnlockSeconds <= 0)
        return "Locked — no auto-unlock"
    return "Locked — " + formatCountdown(remaining) + " left"
}
