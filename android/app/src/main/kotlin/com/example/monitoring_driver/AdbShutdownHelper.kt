package com.example.monitoring_driver

import android.util.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyPairGenerator
import java.security.interfaces.RSAPrivateKey
import java.security.Signature
import android.util.Base64

/**
 * Minimal ADB protocol client that connects to localhost:5555 and executes
 * shell commands as the shell user. Used to shutdown the device without root.
 */
object AdbShutdownHelper {

    private const val TAG = "AdbShutdownHelper"
    private const val ADB_PORT = 5555
    private const val A_CNXN = 0x4e584e43
    private const val A_AUTH = 0x48545541
    private const val A_OPEN = 0x4e45504f
    private const val A_OKAY = 0x59414b4f
    private const val A_WRTE = 0x45545257
    private const val A_CLSE = 0x45534c43
    private const val AUTH_TOKEN = 1
    private const val AUTH_SIGNATURE = 2
    private const val AUTH_RSAPUBLICKEY = 3
    private const val VERSION = 0x01000001
    private const val MAX_PAYLOAD = 256 * 1024

    private var rsaPrivateKey: RSAPrivateKey? = null
    private var rsaPublicKeyBase64: String? = null

    init {
        generateKeyPair()
    }

    private fun generateKeyPair() {
        try {
            val kpg = KeyPairGenerator.getInstance("RSA")
            kpg.initialize(2048)
            val kp = kpg.generateKeyPair()
            rsaPrivateKey = kp.private as RSAPrivateKey
            rsaPublicKeyBase64 = Base64.encodeToString(kp.public.encoded, Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to generate RSA key: ${e.message}")
        }
    }

    fun shutdown(): Boolean {
        return executeCommand("reboot -p")
    }

    fun executeCommand(command: String): Boolean {
        try {
            val socket = Socket("127.0.0.1", ADB_PORT)
            socket.soTimeout = 10_000
            val output = DataOutputStream(socket.getOutputStream())
            val input = DataInputStream(socket.getInputStream())

            // Send CNXN
            val identity = "host::features=shell_v2\u0000"
            sendMessage(output, A_CNXN, VERSION, MAX_PAYLOAD, identity.toByteArray())

            // Read response (expect CNXN or AUTH)
            var msg = readMessage(input)
            if (msg == null) {
                socket.close()
                return false
            }

            // Handle AUTH challenge
            if (msg.command == A_AUTH) {
                if (msg.arg0 == AUTH_TOKEN) {
                    // Sign the token
                    val signed = signToken(msg.data)
                    if (signed != null) {
                        sendMessage(output, A_AUTH, AUTH_SIGNATURE, 0, signed)
                        msg = readMessage(input)

                        // If still AUTH, send public key (device will show dialog)
                        if (msg != null && msg.command == A_AUTH) {
                            val pubKey = (rsaPublicKeyBase64 + " adb_client\u0000").toByteArray()
                            sendMessage(output, A_AUTH, AUTH_RSAPUBLICKEY, 0, pubKey)
                            msg = readMessage(input)
                        }
                    }
                }
            }

            if (msg == null || msg.command != A_CNXN) {
                Log.e(TAG, "Connection failed, got: ${msg?.command}")
                socket.close()
                return false
            }

            Log.i(TAG, "ADB connected, sending command: $command")

            // Open shell with command
            val shellCmd = "shell:$command\u0000"
            sendMessage(output, A_OPEN, 1, 0, shellCmd.toByteArray())

            // Wait for OKAY
            msg = readMessage(input)
            if (msg != null && msg.command == A_OKAY) {
                Log.i(TAG, "Command accepted, device should shut down")
                socket.close()
                return true
            }

            Log.e(TAG, "Command not accepted: ${msg?.command}")
            socket.close()
            return false
        } catch (e: Exception) {
            Log.e(TAG, "ADB shutdown failed: ${e.message}")
            return false
        }
    }

    private fun signToken(token: ByteArray?): ByteArray? {
        if (token == null || rsaPrivateKey == null) return null
        return try {
            val sig = Signature.getInstance("SHA1withRSA")
            sig.initSign(rsaPrivateKey)
            sig.update(token)
            sig.sign()
        } catch (e: Exception) {
            Log.e(TAG, "Sign failed: ${e.message}")
            null
        }
    }

    private fun sendMessage(out: DataOutputStream, command: Int, arg0: Int, arg1: Int, data: ByteArray) {
        val buf = ByteBuffer.allocate(24 + data.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(command)
        buf.putInt(arg0)
        buf.putInt(arg1)
        buf.putInt(data.size)
        buf.putInt(data.fold(0) { acc, b -> acc + (b.toInt() and 0xFF) })
        buf.putInt(command xor -1)
        buf.put(data)
        out.write(buf.array())
        out.flush()
    }

    private fun readMessage(input: DataInputStream): AdbMessage? {
        return try {
            val header = ByteArray(24)
            input.readFully(header)
            val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val command = buf.int
            val arg0 = buf.int
            val arg1 = buf.int
            val dataLen = buf.int
            buf.int // crc
            buf.int // magic

            val data = if (dataLen > 0) {
                val d = ByteArray(dataLen)
                input.readFully(d)
                d
            } else null

            AdbMessage(command, arg0, arg1, data)
        } catch (e: Exception) {
            Log.e(TAG, "Read failed: ${e.message}")
            null
        }
    }

    private data class AdbMessage(val command: Int, val arg0: Int, val arg1: Int, val data: ByteArray?)
}
