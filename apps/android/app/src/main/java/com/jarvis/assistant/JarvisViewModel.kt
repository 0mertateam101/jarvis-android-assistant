package com.jarvis.assistant

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// JarvisViewModel — Don's command centre state + the text-command parser.
// Commands (typed or spoken — voice text lands here via VoiceInput):
//   create portal <name>                → creates a portal (slug auto-made)
//   invite <email> to <portal slug>     → generates a code, shown ONCE
//   block <email> on <portal slug>      → block + terminate (policy)
//   list portals                        → refresh the portal list
//   list methods                        → refresh the payment-method list
//   show traffic <portal slug>          → load the security report
// Anything else is shown as "I don't know that command yet" — Jarvis
// never guesses at an API call, and never sends anything without Don's
// explicit command (human approval gate).

data class JarvisUiState(
    val loggedIn: Boolean = false,
    val portals: List<Portal> = emptyList(),
    val methods: List<PaymentMethod> = emptyList(),
    val grants: List<Grant> = emptyList(),
    val traffic: List<TrafficLog> = emptyList(),
    val assignedMethods: List<PaymentMethod> = emptyList(),
    val selectedPortal: Portal? = null,
    val lastInvite: InviteResult? = null,
    val message: String = "",
    val error: String = "",
    val busy: Boolean = false,
)

class JarvisViewModel(private val api: ApiClient = ApiClient()) : ViewModel() {

    private val _state = MutableStateFlow(JarvisUiState())
    val state: StateFlow<JarvisUiState> = _state

    private fun update(fn: (JarvisUiState) -> JarvisUiState) { _state.value = fn(_state.value) }
    private fun setMessage(m: String) = update { it.copy(message = m, error = "") }
    private fun setError(e: String) = update { it.copy(error = e, message = "") }

    /** Surface an error from outside the parser (e.g. voice input). */
    fun reportError(message: String) = setError(message)

    fun login(email: String, password: String) {
        update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { api.loginAdmin(email, password) }
                refresh()
                update { it.copy(loggedIn = true, busy = false) }
                setMessage("Signed in as Don.")
            } catch (e: Exception) {
                update { it.copy(busy = false) }
                setError(e.message ?: "Sign-in failed.")
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            try {
                val portals = withContext(Dispatchers.IO) { api.listPortals() }
                val methods = withContext(Dispatchers.IO) { api.listPaymentMethods() }
                update { it.copy(portals = portals, methods = methods) }
            } catch (e: Exception) { setError(e.message ?: "Could not load data.") }
        }
    }

    fun selectPortal(portal: Portal) {
        update { it.copy(selectedPortal = portal, grants = emptyList(), traffic = emptyList(), assignedMethods = emptyList(), lastInvite = null) }
        viewModelScope.launch {
            try {
                val grants = withContext(Dispatchers.IO) { api.listGrants(portal.id) }
                val traffic = withContext(Dispatchers.IO) { api.listTraffic(portal.id) }
                val assigned = withContext(Dispatchers.IO) { api.assignedMethods(portal.id) }
                update { it.copy(grants = grants, traffic = traffic, assignedMethods = assigned) }
            } catch (e: Exception) { setError(e.message ?: "Could not load portal details.") }
        }
    }

    fun createPaymentMethod(type: String, label: String, handle: String) {
        if (type.isBlank() || handle.isBlank()) { setError("Give the method a type and a handle first."); return }
        update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { api.createPaymentMethod(type.trim().uppercase(), label.ifBlank { type.trim().uppercase() }, handle.trim()) }
                update { it.copy(busy = false) }
                setMessage("Payment method '$label' added.")
                refresh()
            } catch (e: Exception) { update { it.copy(busy = false) }; setError(e.message ?: "Could not add payment method.") }
        }
    }

    fun assignMethod(method: PaymentMethod, portal: Portal) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { api.assignMethod(portal.id, method.id) }
                setMessage("${method.label} assigned to ${portal.name}.")
                selectPortal(portal)
            } catch (e: Exception) { setError(e.message ?: "Could not assign method.") }
        }
    }

    fun unassignMethod(method: PaymentMethod, portal: Portal) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { api.unassignMethod(portal.id, method.id) }
                setMessage("${method.label} removed from ${portal.name}.")
                selectPortal(portal)
            } catch (e: Exception) { setError(e.message ?: "Could not remove method.") }
        }
    }

    fun invite(email: String, portal: Portal) {
        update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) { api.invite(portal.id, email) }
                update { it.copy(busy = false, lastInvite = result) }
                setMessage("Code for ${result.email} — show it once, it is not stored: ${result.code}")
                selectPortal(portal)
            } catch (e: Exception) { update { it.copy(busy = false) }; setError(e.message ?: "Invite failed.") }
        }
    }

    fun block(email: String, portal: Portal, reason: String = "Policy violation") {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { api.blockUser(portal.id, email, reason) }
                setMessage("Blocked and terminated $email on ${portal.name}.")
                selectPortal(portal)
            } catch (e: Exception) { setError(e.message ?: "Block failed.") }
        }
    }

    fun createPortal(name: String) {
        val slug = name.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')
        if (slug.isBlank()) { setError("Give the portal a name first."); return }
        update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { api.createPortal(name, slug) }
                update { it.copy(busy = false) }
                setMessage("Portal '$name' created.")
                refresh()
            } catch (e: Exception) { update { it.copy(busy = false) }; setError(e.message ?: "Could not create portal.") }
        }
    }

    /** Parse a typed or spoken command into a real API call. */
    fun handleCommand(raw: String) {
        val command = raw.trim()
        if (command.isBlank()) return
        val inviteMatch = Regex("""^invite\s+(\S+@\S+)\s+to\s+(\S+)$""", RegexOption.IGNORE_CASE).find(command)
        val blockMatch = Regex("""^block\s+(\S+@\S+)\s+on\s+(\S+)$""", RegexOption.IGNORE_CASE).find(command)
        val createMatch = Regex("""^create\s+portal\s+(.+)$""", RegexOption.IGNORE_CASE).find(command)
        val trafficMatch = Regex("""^show\s+traffic\s+(\S+)$""", RegexOption.IGNORE_CASE).find(command)
        when {
            command.equals("list portals", ignoreCase = true) -> { refresh(); setMessage("Portals refreshed.") }
            command.equals("list methods", ignoreCase = true) -> { refresh(); setMessage("Payment methods refreshed.") }
            inviteMatch != null -> {
                val (email, slug) = inviteMatch.destructured
                val portal = _state.value.portals.find { it.slug == slug }
                    ?: run { setError("No portal with slug '$slug'."); return }
                invite(email, portal)
            }
            blockMatch != null -> {
                val (email, slug) = blockMatch.destructured
                val portal = _state.value.portals.find { it.slug == slug }
                    ?: run { setError("No portal with slug '$slug'."); return }
                block(email, portal)
            }
            createMatch != null -> createPortal(createMatch.groupValues[1].trim())
            trafficMatch != null -> {
                val slug = trafficMatch.groupValues[1]
                val portal = _state.value.portals.find { it.slug == slug }
                    ?: run { setError("No portal with slug '$slug'."); return }
                selectPortal(portal); setMessage("Traffic report for ${portal.name} loaded.")
            }
            else -> setError("I don't know that command yet. Try: create portal <name> · invite <email> to <portal> · block <email> on <portal> · list portals")
        }
    }

    /** Voice transcript lands here — same parser as typed commands. */
    fun handleVoiceTranscript(text: String) { handleCommand(text) }
}
