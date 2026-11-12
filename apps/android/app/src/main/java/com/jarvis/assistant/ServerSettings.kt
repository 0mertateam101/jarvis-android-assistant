package com.jarvis.assistant

import android.content.Context
import java.net.URI

// Server address setting (Issue #17) — which JARVIS server the Android
// app talks to. Don sets it on the sign-in screen; it is stored in
// SharedPreferences on the phone only: never in the repo, never in logs,
// never sent anywhere except as the API base URL. The sign-in itself is
// unchanged (owner email + password → ADMIN JWT).

object ServerSettings {

    /** Emulator default: the emulator's alias for the host's localhost:4000.
     *  On a physical phone this goes nowhere — Don must type a reachable
     *  address (LAN IP on the same Wi-Fi, or a deployed https:// URL). */
    const val DEFAULT_BASE_URL = "http://10.0.2.2:4000"

    private const val PREFS_NAME = "jarvis_server"
    private const val KEY_BASE_URL = "base_url"

    /** Trim, drop trailing slashes, and check the input is a usable
     *  http(s) URL with a host. Returns the normalized URL, or null
     *  when the input is not one (nothing is saved in that case). */
    fun normalize(raw: String): String? {
        val trimmed = raw.trim().trimEnd('/')
        if (trimmed.isEmpty()) return null
        if (trimmed.any { it == ' ' || it == '\t' || it == '\n' }) return null
        val uri = try {
            URI(trimmed)
        } catch (e: Exception) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = uri.host ?: return null
        if (host.isBlank()) return null
        return trimmed
    }

    /** The saved server address, or the emulator default when nothing
     *  valid has been saved yet. Never throws. */
    fun load(context: Context): String {
        val stored = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_BASE_URL, null)
        return stored?.let { normalize(it) } ?: DEFAULT_BASE_URL
    }

    /** Validate + save a new server address. Returns the normalized URL
     *  that was saved, or null when the input is not a valid http(s) URL
     *  (the previously saved address is left untouched). */
    fun save(context: Context, raw: String): String? {
        val normalized = normalize(raw) ?: return null
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_BASE_URL, normalized)
            .apply()
        return normalized
    }
}
