package com.yusukendama.cataract_surgery_note

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false
    private val timeContextReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            eventSink?.success(mapOf("kind" to "contextChanged"))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(
            messenger,
            "cataract_surgery_note/analysis_time_context",
        ).setMethodCallHandler { call, result ->
            if (call.method == "timezoneIdentifier") {
                result.success(TimeZone.getDefault().id)
            } else {
                result.notImplemented()
            }
        }
        EventChannel(
            messenger,
            "cataract_surgery_note/analysis_time_events",
        ).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        if (!receiverRegistered) {
            registerReceiver(
                timeContextReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_DATE_CHANGED)
                    addAction(Intent.ACTION_TIME_CHANGED)
                    addAction(Intent.ACTION_TIMEZONE_CHANGED)
                },
            )
            receiverRegistered = true
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        unregisterTimeContextReceiver()
    }

    override fun onDestroy() {
        unregisterTimeContextReceiver()
        super.onDestroy()
    }

    private fun unregisterTimeContextReceiver() {
        if (receiverRegistered) {
            unregisterReceiver(timeContextReceiver)
            receiverRegistered = false
        }
    }
}
