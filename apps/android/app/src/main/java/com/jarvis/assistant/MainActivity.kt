package com.jarvis.assistant

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

// JARVIS — Don's control app (ADMIN only).
// Screens in one file for the skeleton (Prompt 10 splits them if needed):
//   1. Sign in (admin email + password → JWT)
//   2. Jarvis command bar (text + mic) + portal list
//   3. Portal detail: invite by email (code shown ONCE), grants,
//      payment methods, traffic/security report, block/terminate,
//      ID verification review (verify / reject).

class MainActivity : ComponentActivity() {

    private val viewModel: JarvisViewModel by viewModels()
    private lateinit var voiceInput: VoiceInput

    private val micPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) startListening() else viewModel.reportError("Microphone permission is needed for voice commands. You can still type them.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        voiceInput = VoiceInput(this)
        // Point the API client at the saved server address (or the
        // emulator default) before anything signs in (Issue #17).
        viewModel.loadServerUrl(applicationContext)
        setContent {
            val state by viewModel.state.collectAsState()
            JarvisScreen(
                state = state,
                onLogin = { email, password -> viewModel.login(email, password) },
                onSaveServerUrl = { raw -> viewModel.saveServerUrl(applicationContext, raw) },
                onCommand = { viewModel.handleCommand(it) },
                onMic = ::onMicTapped,
                onSelectPortal = { viewModel.selectPortal(it) },
                onInvite = { email, portal -> viewModel.invite(email, portal) },
                onBlock = { email, portal -> viewModel.block(email, portal) },
                onCreateMethod = { type, label, handle -> viewModel.createPaymentMethod(type, label, handle) },
                onAssignMethod = { method, portal -> viewModel.assignMethod(method, portal) },
                onUnassignMethod = { method, portal -> viewModel.unassignMethod(method, portal) },
                onReviewVerification = { verification, portal, status -> viewModel.reviewVerification(verification, portal, status) },
            )
        }
    }

    private fun onMicTapped() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
        } else startListening()
    }

    private fun startListening() {
        voiceInput.listenOnce(
            onResult = { text -> viewModel.handleVoiceTranscript(text) },
            onError = { message -> viewModel.reportError(message) },
        )
    }
}

@Composable
fun JarvisScreen(
    state: JarvisUiState,
    onLogin: (String, String) -> Unit,
    onSaveServerUrl: (String) -> Unit,
    onCommand: (String) -> Unit,
    onMic: () -> Unit,
    onSelectPortal: (Portal) -> Unit,
    onInvite: (String, Portal) -> Unit,
    onBlock: (String, Portal) -> Unit,
    onCreateMethod: (String, String, String) -> Unit,
    onAssignMethod: (PaymentMethod, Portal) -> Unit,
    onUnassignMethod: (PaymentMethod, Portal) -> Unit,
    onReviewVerification: (IdVerification, Portal, String) -> Unit,
) {
    if (!state.loggedIn) {
        LoginScreen(onLogin = onLogin, error = state.error, serverUrl = state.serverUrl, onSaveServerUrl = onSaveServerUrl)
        return
    }
    LazyColumn(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Text("JARVIS", fontWeight = FontWeight.Bold)
            Text("Tell me what to do — type it or tap the mic.")
            Spacer(Modifier.height(12.dp))
            CommandBar(onCommand = onCommand, onMic = onMic)
            if (state.message.isNotBlank()) Text(state.message, color = Color(0xFF1B5E20))
            if (state.error.isNotBlank()) Text(state.error, color = Color.Red)
            if (state.lastInvite != null) {
                Text("Code for ${state.lastInvite.email}: ${state.lastInvite.code} — show once, it is not stored.", fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(16.dp))
            Text("Portals", fontWeight = FontWeight.Bold)
        }
        items(state.portals) { portal ->
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Text("${portal.name} (${portal.slug})", modifier = Modifier.weight(1f))
                OutlinedButton(onClick = { onSelectPortal(portal) }) { Text("Open") }
            }
        }
        state.selectedPortal?.let { portal ->
            item {
                Spacer(Modifier.height(16.dp))
                Text("Portal: ${portal.name}", fontWeight = FontWeight.Bold)
                PortalDetail(
                    portal = portal,
                    grants = state.grants,
                    traffic = state.traffic,
                    verifications = state.verifications,
                    methods = state.methods,
                    assignedMethods = state.assignedMethods,
                    onInvite = onInvite,
                    onBlock = onBlock,
                    onCreateMethod = onCreateMethod,
                    onAssignMethod = onAssignMethod,
                    onUnassignMethod = onUnassignMethod,
                    onReviewVerification = onReviewVerification,
                )
            }
        }
    }
}

@Composable
fun LoginScreen(
    onLogin: (String, String) -> Unit,
    error: String,
    serverUrl: String,
    onSaveServerUrl: (String) -> Unit,
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    // Prefilled with the current address; resets to it whenever a new
    // address is saved (the normalized value comes back via serverUrl).
    var serverField by remember(serverUrl) { mutableStateOf(serverUrl) }
    Column(modifier = Modifier.fillMaxSize().padding(24.dp)) {
        Text("JARVIS — sign in", fontWeight = FontWeight.Bold)
        OutlinedTextField(value = email, onValueChange = { email = it }, label = { Text("Email") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = password, onValueChange = { password = it }, label = { Text("Password") }, modifier = Modifier.fillMaxWidth())
        if (error.isNotBlank()) Text(error, color = Color.Red)
        Spacer(Modifier.height(12.dp))
        Button(onClick = { onLogin(email, password) }, modifier = Modifier.fillMaxWidth()) { Text("Sign in") }
        Spacer(Modifier.height(20.dp))
        // Server address setting (Issue #17): the sign-in screen always
        // shows what the app is pointed at, and Don can change it here.
        Text("Server: $serverUrl")
        Text("On a real phone this must be a reachable server address — the 10.0.2.2 default only works in the emulator.")
        OutlinedTextField(value = serverField, onValueChange = { serverField = it }, label = { Text("Server address, e.g. http://192.168.1.10:4000") }, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = { onSaveServerUrl(serverField) }, modifier = Modifier.fillMaxWidth()) { Text("Save server") }
    }
}

@Composable
fun CommandBar(onCommand: (String) -> Unit, onMic: () -> Unit) {
    var text by remember { mutableStateOf("") }
    Row(modifier = Modifier.fillMaxWidth()) {
        OutlinedTextField(value = text, onValueChange = { text = it }, label = { Text("Ask Jarvis…") }, modifier = Modifier.weight(1f))
        Button(onClick = { onCommand(text); text = "" }) { Text("Send") }
        OutlinedButton(onClick = onMic) { Text("Mic") }
    }
    Text("Try: create portal VIP Coaching · invite jane@example.com to vip-coaching · block bad@example.com on vip-coaching")
}

@Composable
fun PortalDetail(
    portal: Portal,
    grants: List<Grant>,
    traffic: List<TrafficLog>,
    verifications: List<IdVerification>,
    methods: List<PaymentMethod>,
    assignedMethods: List<PaymentMethod>,
    onInvite: (String, Portal) -> Unit,
    onBlock: (String, Portal) -> Unit,
    onCreateMethod: (String, String, String) -> Unit,
    onAssignMethod: (PaymentMethod, Portal) -> Unit,
    onUnassignMethod: (PaymentMethod, Portal) -> Unit,
    onReviewVerification: (IdVerification, Portal, String) -> Unit,
) {
    var inviteEmail by remember { mutableStateOf("") }
    var blockEmail by remember { mutableStateOf("") }
    var methodType by remember { mutableStateOf("") }
    var methodLabel by remember { mutableStateOf("") }
    var methodHandle by remember { mutableStateOf("") }
    Column {
        Text("Invite by email")
        Row {
            OutlinedTextField(value = inviteEmail, onValueChange = { inviteEmail = it }, label = { Text("customer@example.com") }, modifier = Modifier.weight(1f))
            Button(onClick = { onInvite(inviteEmail, portal); inviteEmail = "" }) { Text("Invite") }
        }
        Text("Access grants")
        grants.forEach { g -> Text("${g.email} — ${g.status}") }
        if (grants.isEmpty()) Text("No grants yet.")
        Spacer(Modifier.height(8.dp))
        Text("Block / terminate (policy violation)")
        Row {
            OutlinedTextField(value = blockEmail, onValueChange = { blockEmail = it }, label = { Text("email to block") }, modifier = Modifier.weight(1f))
            Button(onClick = { onBlock(blockEmail, portal); blockEmail = "" }) { Text("Block") }
        }
        Spacer(Modifier.height(8.dp))
        Text("Payment methods", fontWeight = FontWeight.Bold)
        Text("Add a method — type e.g. CASH_APP, VENMO, CHIME, ZELLE, BTC, LTC, XMR, ETH, USDT, USDC, DOGE, PAYPAL, CARD, BANK.")
        OutlinedTextField(value = methodType, onValueChange = { methodType = it }, label = { Text("Type, e.g. CASH_APP") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = methodLabel, onValueChange = { methodLabel = it }, label = { Text("Label, e.g. Cash App — APF") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = methodHandle, onValueChange = { methodHandle = it }, label = { Text("Public handle or address — never a private key") }, modifier = Modifier.fillMaxWidth())
        Button(onClick = { onCreateMethod(methodType, methodLabel, methodHandle); methodType = ""; methodLabel = ""; methodHandle = "" }) { Text("Add method") }
        Spacer(Modifier.height(8.dp))
        Text("Assign to ${portal.name}")
        if (methods.isEmpty()) Text("No payment methods yet — add one above.")
        methods.forEach { method ->
            val assigned = assignedMethods.any { it.id == method.id }
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Text("${method.type} — ${method.label} (${method.handle})", modifier = Modifier.weight(1f))
                if (assigned) {
                    OutlinedButton(onClick = { onUnassignMethod(method, portal) }) { Text("Remove") }
                } else {
                    Button(onClick = { onAssignMethod(method, portal) }) { Text("Assign") }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text("ID verifications (review)", fontWeight = FontWeight.Bold)
        Text("Customers upload front, back and a selfie holding the ID. Passports are never accepted. View the pictures in the portal app or browser — only the status is shown here.")
        verifications.forEach { v ->
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Text("${v.email} — ${v.idType} — ${v.status}", modifier = Modifier.weight(1f))
                if (v.status == "PENDING") {
                    Button(onClick = { onReviewVerification(v, portal, "VERIFIED") }) { Text("Verify") }
                    OutlinedButton(onClick = { onReviewVerification(v, portal, "REJECTED") }) { Text("Reject") }
                }
            }
        }
        if (verifications.isEmpty()) Text("No ID verifications yet.")
        Spacer(Modifier.height(8.dp))
        Text("Unauthorised visits (reverse lookup)")
        traffic.forEach { t -> Text("${t.ip} — ${t.city ?: "UNKNOWN"}, ${t.country ?: ""} — ${t.isp ?: "UNKNOWN"}") }
        if (traffic.isEmpty()) Text("No unauthorised visits logged.")
    }
}
