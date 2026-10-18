package app.calculatorspace.calculator_messenger

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

class TelecomConnectionService : ConnectionService() {
    companion object {
        private const val ACCOUNT_ID = "calculator_messenger_calls"
        var activeConnection: CalculatorConnection? = null
        var onAnswerCall: ((String) -> Unit)? = null
        var onRejectCall: ((String) -> Unit)? = null

        fun getAccountHandle(context: Context): PhoneAccountHandle {
            return PhoneAccountHandle(
                ComponentName(context, TelecomConnectionService::class.java),
                ACCOUNT_ID
            )
        }

        fun registerAccount(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    val manager = context.getSystemService(TelecomManager::class.java) ?: return
                    val handle = getAccountHandle(context)
                    val account = PhoneAccount.builder(handle, "Calculator")
                        .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                        .setIcon(android.graphics.drawable.Icon.createWithResource(context, R.mipmap.ic_launcher))
                        .setShortDescription("Private VoIP calls")
                        .build()
                    manager.registerPhoneAccount(account)
                } catch (_: Exception) {}
            }
        }

        fun startIncomingCall(context: Context, callId: String, callerName: String, isVideo: Boolean) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    registerAccount(context)
                    val manager = context.getSystemService(TelecomManager::class.java) ?: return
                    val handle = getAccountHandle(context)
                    val extras = Bundle().apply {
                        putString("callId", callId)
                        putString("name", callerName)
                        putBoolean("video", isVideo)
                        putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                    }
                    manager.addNewIncomingCall(handle, extras)
                } catch (_: Exception) {}
            }
        }

        fun endCall(callId: String) {
            activeConnection?.let {
                if (it.callId == callId) {
                    it.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
                    it.destroy()
                    activeConnection = null
                }
            }
        }
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: "unknown"
        val name = extras.getString("name") ?: "Caller"
        val isVideo = extras.getBoolean("video", false)

        val connection = CalculatorConnection(callId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            connection.connectionProperties = Connection.PROPERTY_SELF_MANAGED
        }
        connection.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
        connection.setAddress(Uri.fromParts("tel", callId, null), TelecomManager.PRESENTATION_ALLOWED)
        if (isVideo) {
            connection.videoState = android.telecom.VideoProfile.STATE_BIDIRECTIONAL
        }
        connection.setRinging()
        activeConnection = connection
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        activeConnection = null
    }

    class CalculatorConnection(val callId: String) : Connection() {
        init {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                connectionProperties = PROPERTY_SELF_MANAGED
            }
        }

        override fun onAnswer() {
            setActive()
            onAnswerCall?.invoke(callId)
        }

        override fun onReject() {
            setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
            destroy()
            if (activeConnection == this) activeConnection = null
            onRejectCall?.invoke(callId)
        }

        override fun onDisconnect() {
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            destroy()
            if (activeConnection == this) activeConnection = null
        }
    }
}
