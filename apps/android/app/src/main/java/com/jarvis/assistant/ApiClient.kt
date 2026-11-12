package com.jarvis.assistant

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

// JARVIS API client — talks to the server in docs/API.md.
// BASE_URL: emulator → 10.0.2.2 ; physical device → your machine's LAN IP.
// e.g. "http://192.168.1.10:4000". Change it here, or set it from a
// BuildConfig field (Copilot Prompt 10).

data class Portal(val id: String, val slug: String, val name: String, val currency: String, val status: String)
data class PaymentMethod(val id: String, val type: String, val label: String, val handle: String)
data class Grant(val id: String, val email: String, val status: String)
data class TrafficLog(val ip: String, val country: String?, val city: String?, val isp: String?, val hasAccess: Boolean, val createdAt: String)
data class InviteResult(val email: String, val code: String)

class ApiClient {
    companion object {
        // TODO (Prompt 10): move to BuildConfig / a settings screen.
        const val BASE_URL = "http://10.0.2.2:4000"
    }

    private val client = OkHttpClient()
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    var adminToken: String? = null
        private set

    private fun request(path: String, method: String, body: JSONObject? = null, token: String? = null): JSONObject {
        val builder = Request.Builder().url("$BASE_URL$path")
        val auth = token ?: adminToken
        if (auth != null) builder.header("Authorization", "Bearer $auth")
        val requestBody = (body?.toString() ?: "").toRequestBody(jsonMedia)
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post(requestBody)
            "PATCH" -> builder.patch(requestBody)
            "DELETE" -> builder.delete()
            else -> builder.method(method, requestBody)
        }
        client.newCall(builder.build()).execute().use { res ->
            val text = res.body?.string().orEmpty()
            val json = if (text.isBlank()) JSONObject() else JSONObject(text)
            if (!res.isSuccessful) {
                val message = json.optJSONObject("error")?.optString("message") ?: "Request failed (${res.code})"
                throw ApiException(message)
            }
            return json.optJSONObject("data") ?: json
        }
    }

    private fun dataArray(json: JSONObject, key: String): JSONArray = json.optJSONArray(key) ?: JSONArray()

    // --- Auth (Don / ADMIN) ---
    fun loginAdmin(email: String, password: String): String {
        val data = request("/api/auth/login", "POST", JSONObject().put("email", email).put("password", password))
        val token = data.getString("token")
        adminToken = token
        return token
    }

    // --- Portals ---
    fun listPortals(): List<Portal> {
        val data = request("/api/portals", "GET")
        return (0 until dataArray(data, "portals").length()).map { i ->
            val o = dataArray(data, "portals").getJSONObject(i)
            Portal(o.getString("id"), o.getString("slug"), o.getString("name"), o.optString("currency", "USD"), o.getString("status"))
        }
    }

    fun createPortal(name: String, slug: String, currency: String = "USD"): Portal {
        val data = request("/api/portals", "POST", JSONObject().put("name", name).put("slug", slug).put("currency", currency))
        val o = data.getJSONObject("portal")
        return Portal(o.getString("id"), o.getString("slug"), o.getString("name"), o.optString("currency", "USD"), o.getString("status"))
    }

    // --- Access: invite by email → code (shown ONCE, never stored) ---
    fun invite(portalId: String, email: String): InviteResult {
        val data = request("/api/access/invite", "POST", JSONObject().put("portalId", portalId).put("email", email))
        return InviteResult(email, data.getString("code"))
    }

    fun listGrants(portalId: String): List<Grant> {
        val data = request("/api/access/portals/$portalId/grants", "GET")
        return (0 until dataArray(data, "grants").length()).map { i ->
            val o = dataArray(data, "grants").getJSONObject(i)
            Grant(o.getString("id"), o.getString("email"), o.getString("status"))
        }
    }

    // --- Payment methods ---
    fun listPaymentMethods(): List<PaymentMethod> {
        val data = request("/api/payment-methods", "GET")
        return (0 until dataArray(data, "methods").length()).map { i ->
            val o = dataArray(data, "methods").getJSONObject(i)
            PaymentMethod(o.getString("id"), o.getString("type"), o.getString("label"), o.getString("handle"))
        }
    }

    fun createPaymentMethod(type: String, label: String, handle: String): PaymentMethod {
        val data = request("/api/payment-methods", "POST", JSONObject().put("type", type).put("label", label).put("handle", handle))
        val o = data.getJSONObject("method")
        return PaymentMethod(o.getString("id"), o.getString("type"), o.getString("label"), o.getString("handle"))
    }

    fun assignMethod(portalId: String, methodId: String) {
        request("/api/portals/$portalId/methods", "POST", JSONObject().put("paymentMethodId", methodId))
    }

    // --- Security: traffic report + block / terminate ---
    fun listTraffic(portalId: String): List<TrafficLog> {
        val data = request("/api/security/portals/$portalId/traffic?hasAccess=false&limit=100", "GET")
        return (0 until dataArray(data, "logs").length()).map { i ->
            val o = dataArray(data, "logs").getJSONObject(i)
            TrafficLog(o.getString("ip"), o.optString("country", null), o.optString("city", null), o.optString("isp", null), o.getBoolean("hasAccess"), o.getString("createdAt"))
        }
    }

    /** Block + terminate a user for a policy violation. */
    fun blockUser(portalId: String, email: String, reason: String) {
        request("/api/security/block", "POST", JSONObject().put("portalId", portalId).put("email", email).put("reason", reason))
    }

    class ApiException(message: String) : Exception(message)
}
