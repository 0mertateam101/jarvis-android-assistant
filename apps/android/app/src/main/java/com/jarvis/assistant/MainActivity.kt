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
//      payment methods, traffic/security report, block/terminate.

class MainActivity : ComponentActivity() {

    private val viewModel: JarvisViewModel by viewModels()
    private lateinit var voiceInput: VoiceInput

    private val micPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) startListening() else viewModel.handleCommand("")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        voiceInput = VoiceInput(this)
        setContent {
            val state by viewModel.state.collectAsState()
            JarvisScreen(
                state = state,
                onLogin = { email, password -> viewModel.login(email, password) },
                onCommand = { viewModel.handleCommand(it) },
                onMic = ::onMicTapped,
                onSelectPortal = { viewModel.selectPortal(it) },
                onInvite = { email, portal -> viewModel.invite(email, portal) },
                onBlock = { email, portal -> viewModel.block(email, portal) },
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
            onError = { /* Surface via a command error: reuse the parser's error path */ },
        )
    }
}

@Composable
fun JarvisScreen(
    state: JarvisUiState,
    onLogin: (String, String) -> Unit,
    onCommand: (String) -> Unit,
    onMic: () -> Unit,
    onSelectPortal: (Portal) -> Unit,
    onInvite: (String, Portal) -> Unit,
    onBlock: (String, Portal) -> Unit,
) {
    if (!state.loggedIn) {
        LoginScreen(onLogin = onLogin, error = state.error)
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
                PortalDetail(portal = portal, grants = state.grants, traffic = state.traffic, onInvite = onInvite, onBlock = onBlock)
            }
        }
    }
}

@Composable
fun LoginScreen(onLogin: (String, String) -> Unit, error: String) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    Column(modifier = Modifier.fillMaxSize().padding(24.dp)) {
        Text("JARVIS — sign in", fontWeight = FontWeight.Bold)
        OutlinedTextField(value = email, onValueChange = { email = it }, label = { Text("Email") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = password, onValueChange = { password = it }, label = { Text("Password") }, modifier = Modifier.fillMaxWidth())
        if (error.isNotBlank()) Text(error, color = Color.Red)
        Spacer(Modifier.height(12.dp))
        Button(onClick = { onLogin(email, password) }, modifier = Modifier.fillMaxWidth()) { Text("Sign in") }
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
    onInvite: (String, Portal) -> Unit,
    onBlock: (String, Portal) -> Unit,
) {
    var inviteEmail by remember { mutableStateOf("") }
    var blockEmail by remember { mutableStateOf("") }
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
        Text("Unauthorised visits (reverse lookup)")
        traffic.forEach { t -> Text("${t.ip} — ${t.city ?: "UNKNOWN"}, ${t.country ?: ""} — ${t.isp ?: "UNKNOWN"}") }
        if (traffic.isEmpty()) Text("No unauthorised visits logged.")
    }
}
