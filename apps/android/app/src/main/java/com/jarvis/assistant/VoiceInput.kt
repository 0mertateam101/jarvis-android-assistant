package com.jarvis.assistant

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.Locale

// Voice input — the ONLY voice entry point (see muse-instructions.md).
// Default: on-device Android SpeechRecognizer. No audio leaves the device.
// Optional Whisper hook: disabled unless WHISPER_API_KEY is set, and even
// then only for the transcribed text — never for background listening.
//
// INTEGRATION POINT (Whisper): if WHISPER_API_KEY is set, send the recorded
// audio to https://api.openai.com/v1/audio/transcriptions with model
// "whisper-1" and return the text. Until then, on-device recognition is
// the whole implementation.

class VoiceInput(private val context: Context) {

    // Set this from BuildConfig / settings when Don opts in to Whisper.
    // Leave null for on-device-only voice (the default).
    var whisperApiKey: String? = null

    fun isAvailable(): Boolean = SpeechRecognizer.isRecognitionAvailable(context)

    /**
     * Listen once and call [onResult] with the best transcript, or
     * [onError] with a human-readable message. Call [stop] to cancel.
     */
    fun listenOnce(onResult: (String) -> Unit, onError: (String) -> Unit) {
        if (!isAvailable()) {
            onError("Voice recognition is not available on this device.")
            return
        }
        val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onPartialResults(partialResults: Bundle?) = Unit
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
            override fun onError(error: Int) {
                recognizer.destroy()
                onError("Voice input failed (error $error). Try typing the command instead.")
            }
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                recognizer.destroy()
                if (text.isBlank()) onError("I didn't catch that. Try again or type it.")
                else onResult(text)
            }
        })
        recognizer.startListening(intent)
    }

    /** Whisper hook — intentionally unimplemented until a key is configured. */
    @Suppress("unused")
    fun transcribeWithWhisper(audioBytes: ByteArray): String {
        val key = whisperApiKey
        require(!key.isNullOrBlank()) { "Whisper is not configured — set WHISPER_API_KEY to enable it." }
        // TODO (Prompt 10): POST multipart audio to
        // https://api.openai.com/v1/audio/transcriptions (model whisper-1),
        // Authorization: Bearer <key>, and return the "text" field.
        throw NotImplementedError("Whisper transcription is not wired yet — see VoiceInput.kt")
    }
}
