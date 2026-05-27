package com.wecodelife.flutter_ble_devices

import android.Manifest
import android.app.Activity
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.jeremyliao.liveeventbus.LiveEventBus
import com.lepu.blepro.constants.Ble
import com.lepu.blepro.event.EventMsgConst
import com.lepu.blepro.event.InterfaceEvent
import com.lepu.blepro.ext.BleServiceHelper
import com.lepu.blepro.objs.Bluetooth
import com.lepu.blepro.objs.BluetoothController
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import no.nordicsemi.android.ble.observer.ConnectionObserver

import cn.icomon.icdevicemanager.ICDeviceManager
import cn.icomon.icdevicemanager.callback.ICScanDeviceDelegate
import cn.icomon.icdevicemanager.model.device.ICDevice
import cn.icomon.icdevicemanager.model.device.ICScanDeviceInfo
import cn.icomon.icdevicemanager.model.device.ICUserInfo
import cn.icomon.icdevicemanager.model.other.ICConstant
import cn.icomon.icdevicemanager.model.other.ICDeviceManagerConfig
import cn.icomon.icdevicemanager.model.data.ICWeightData
import cn.icomon.icdevicemanager.model.data.ICWeightCenterData
import cn.icomon.icdevicemanager.model.data.ICWeightHistoryData
import cn.icomon.icdevicemanager.model.data.ICKitchenScaleData
import cn.icomon.icdevicemanager.model.data.ICRulerData
import cn.icomon.icdevicemanager.model.data.ICSkipData

/**
 * FlutterBleDevicesPlugin — Flutter MethodChannel + EventChannel bridge to Lepu BLE SDK.
 *
 * MethodChannel "viatom_ble"         → commands (scan, connect, startMeasurement, etc.)
 * EventChannel "viatom_ble_stream"   → events  (scan results, connection state, RT data)
 */
class FlutterBleDevicesPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val TAG = "FlutterBleDevicesPlugin"
        private const val METHOD_CHANNEL = "viatom_ble"
        private const val EVENT_CHANNEL = "viatom_ble_stream"
        private const val PERMISSION_REQUEST_CODE = 9527

        /**
         * Pure decision function for [maybeTriggerCatchUp]. Exposed with
         * `internal` visibility so the unit-test module can exercise the
         * full scenario matrix without needing a FlutterPluginBinding or
         * a real device.
         *
         * @param files the fresh fileList as posted by the SDK.
         * @param known baseline set of filenames already seen on this
         *        connection. Not mutated — the caller updates it after.
         * @param autoFetchOnFinish the user's connect-time flag. If
         *        false, this function always returns an empty list.
         * @param hasPendingCatchUp true when this enumeration was
         *        triggered by a recording-finished transition, in which
         *        case the first-list-is-baseline short-circuit is
         *        bypassed (see class-level kdoc on
         *        `pendingCatchUpByModel`).
         */
        internal fun chooseCatchUpTargets(
            files: List<String>,
            known: Set<String>,
            autoFetchOnFinish: Boolean,
            hasPendingCatchUp: Boolean,
        ): List<String> {
            if (!autoFetchOnFinish) return emptyList()
            val isFirstList = known.isEmpty()
            val diff = files.filter { it.isNotBlank() && it !in known }
            return when {
                // Post-`recordingFinished` enumeration: at least one new
                // file exists by definition. Prefer the diff, fall back
                // to the tail of the list (Lepu returns file names as
                // yyyyMMddHHmmss in ascending chronological order).
                hasPendingCatchUp && diff.isNotEmpty() -> diff
                hasPendingCatchUp && files.isNotEmpty() ->
                    listOf(files.last())
                // Plain enumeration on a fresh session → baseline only.
                isFirstList -> emptyList()
                diff.isEmpty() -> emptyList()
                else -> diff
            }
        }
    }

    // ── Flutter binding ─────────────────────────────────────────────────
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var pendingPermissionResult: Result? = null

    // ── SDK state ───────────────────────────────────────────────────────
    private var serviceInitialized = false
    private var connectedModel: Int = -1
    private val mainHandler = Handler(Looper.getMainLooper())

    // Currently-bound iComon scale, set by handleConnect when sdk='icomon'
    // and reset on disconnect; needed because ICDeviceManagerSettingManager
    // APIs (readHistoryData, ...) take an ICDevice instance rather than a
    // mac address.
    private var activeIComonDevice: ICDevice? = null

    // Set of file names already on flash when the consumer connected. Used
    // to diff fresh getFileList responses so we can auto-pull only the
    // *new* files produced while the consumer was connected (mid-recording
    // catch-up). Keyed by Lepu model id so it stays correct if the
    // consumer hops between devices.
    private val knownFilesByModel = mutableMapOf<Int, MutableSet<String>>()

    // Models for which the next `fileList` event must force a catch-up
    // download instead of being treated as a baseline snapshot. Set by
    // onRecordingFinishedTransition() because that transition *is* the
    // SDK telling us a new file just landed on flash: even when this is
    // the session's very first enumeration (knownFilesByModel empty),
    // we must pull at least the newest entry. Without this flag, the
    // first-measurement-of-a-session file was silently skipped by
    // maybeTriggerCatchUp's `isFirstList -> baseline only` branch.
    private val pendingCatchUpByModel = mutableSetOf<Int>()

    // Most-recent file name passed to a `readFile()` for each model. The
    // ER1 family's `continueReadFile(model, fileName)` overload requires
    // the filename of the in-flight transfer, but `pauseReadFile` /
    // `cancelReadFile` only take the model. We cache the filename here
    // so a Dart-driven `continueReadFile()` call (which only carries the
    // model) can still issue the correct command. Cleared on disconnect.
    private val lastReadFileNameByModel = mutableMapOf<Int, String>()

    // Per-family curStatus tracking for the auto-fetch-on-finish logic.
    // The Lepu SDK reports curStatus on every rtData chunk; we trigger a
    // file pull when status transitions into the "saved" terminal state
    // (4 for ER1/ER2, equivalent measureType strings for BP2 / Oxy).
    private var lastEr1CurStatus: Int = -1
    private var lastEr2CurStatus: Int = -1
    private var lastBp2MeasureType: String = ""
    // True after startMeasurement is called for BP2A; cleared when the device
    // first reports STATUS_READY (at which point we fire bp2aCmd0x40 to start
    // inflation). Sending the command immediately on connect races the device's
    // post-connect init and is silently ignored by the firmware.
    private var bp2aAutoStartPending: Boolean = false
    private var autoFetchOnFinish: Boolean = true

    // ── iComon Delegates ────────────────────────────────────────────────
    private val iComonScaleKeywords = listOf("lescale", "icomon", "fi2016", "f4", "qn-scale", "adore", "health scale", "chipsea")

    private val iComonScanDelegate = object : ICScanDeviceDelegate {
        override fun onScanResult(deviceInfo: ICScanDeviceInfo?) {
            deviceInfo?.let {
                val name = (it.name ?: "").lowercase()
                // Only emit devices that look like iComon scales
                val isScale = iComonScaleKeywords.any { kw -> name.contains(kw) }
                if (isScale) {
                    sendEvent(mapOf(
                        "event" to "deviceFound",
                        "name" to (it.name ?: ""),
                        "mac" to it.macAddr,
                        "rssi" to it.rssi,
                        "sdk" to "icomon"
                    ))
                }
            }
        }
    }

    private val iComonDeviceDelegate = object : IComonDelegateBase() {
        override fun onDeviceConnectionChanged(device: ICDevice?, state: ICConstant.ICDeviceConnectState?) {
            device?.let {
                val stateStr = if (state == ICConstant.ICDeviceConnectState.ICDeviceConnectStateConnected) "connected" else "disconnected"
                sendEvent(mapOf(
                    "event" to "connectionState",
                    "state" to stateStr,
                    "mac" to it.macAddr,
                    "sdk" to "icomon"
                ))
            }
        }

        override fun onReceiveMeasureStepData(device: ICDevice?, step: ICConstant.ICMeasureStep?, data2: Any?) {
            if (device == null || step == null || data2 == null) return
            when (step) {
                ICConstant.ICMeasureStep.ICMeasureStepMeasureWeightData -> {
                    (data2 as? ICWeightData)?.let { onReceiveWeightData(device, it) }
                }
                ICConstant.ICMeasureStep.ICMeasureStepMeasureCenterData -> {
                    (data2 as? ICWeightCenterData)?.let {
                        sendEvent(mapOf(
                            "event" to "rtData",
                            "deviceType" to "scale",
                            "deviceFamily" to "icomon",
                            "mac" to device.macAddr,
                            "sdk" to "icomon",
                            "isStabilized" to it.isStabilized,
                            "leftPercent" to it.leftPercent,
                            "rightPercent" to it.rightPercent
                        ))
                    }
                }
                ICConstant.ICMeasureStep.ICMeasureStepHrResult -> {
                    (data2 as? ICWeightData)?.let {
                        sendEvent(mapOf(
                            "event" to "rtData",
                            "deviceType" to "scale",
                            "deviceFamily" to "icomon",
                            "mac" to device.macAddr,
                            "sdk" to "icomon",
                            "hr" to it.hr,
                            "step" to "ICMeasureStepHrResult"
                        ))
                    }
                }
                ICConstant.ICMeasureStep.ICMeasureStepMeasureOver -> {
                    (data2 as? ICWeightData)?.let {
                        it.isStabilized = true
                        onReceiveWeightData(device, it)
                    }
                }
                else -> {}
            }
        }

        override fun onReceiveWeightData(device: ICDevice?, data: ICWeightData?) {
            if (device == null || data == null) return

            // ICWeightData declares every body-composition field as a
            // Java `double` (verified against ICDeviceManager.aar's
            // classes.jar), so no .toDouble() conversion is needed.
            val w = data.weight_kg
            // Round helper
            fun r1(v: Double) = Math.round(v * 10.0) / 10.0
            fun r2(v: Double) = Math.round(v * 100.0) / 100.0

            // Convert percentages to kg where the original app shows kg
            val muscleKg = r1(data.musclePercent / 100.0 * w)
            val skeletalMuscleKg = r1(data.smPercent / 100.0 * w)
            val fatMassKg = r1(data.bodyFatPercent / 100.0 * w)

            sendEvent(mapOf(
                "event" to "rtData",
                "deviceType" to "scale",
                "deviceFamily" to "icomon",
                "mac" to device.macAddr,
                "sdk" to "icomon",
                "isLocked" to data.isStabilized,
                "weightKg" to r2(w),
                "bmi" to r1(data.bmi),
                "fat" to r1(data.bodyFatPercent),
                "fat_mass" to fatMassKg,
                "muscle" to muscleKg,
                "musclePercent" to r1(data.musclePercent),
                "water" to r1(data.moisturePercent),
                "bone" to r1(data.boneMass),
                "protein" to r1(data.proteinPercent),
                "bmr" to data.bmr,
                "visceral" to r1(data.visceralFat),
                "skeletal_muscle" to skeletalMuscleKg,
                "skeletalMusclePercent" to r1(data.smPercent),
                "subcutaneous" to r1(data.subcutaneousFatPercent),
                "body_age" to data.physicalAge,
                "ci" to r1(data.smi),
                "body_score" to r1(data.bodyScore),
                "temperature" to data.temperature,
                "heartRate" to data.hr,
                "impedance" to data.imp
            ))
        }

        // ── History-data callbacks ──────────────────────────────────
        // The iComon SDK fires these once per stored offline measurement
        // when:
        //   - the user steps on the scale without the phone present
        //     (data is auto-uploaded after the next BLE reconnect), or
        //   - the consumer explicitly invokes
        //     ICDeviceManagerSettingManager.readHistoryData(device).
        //
        // The Welland scale firmware keeps roughly the most recent ~64
        // measurements; older entries are discarded silently.

        override fun onReceiveWeightHistoryData(
            device: ICDevice?,
            data: ICWeightHistoryData?,
        ) {
            if (device == null || data == null) return
            sendEvent(mapOf(
                "event"        to "historyData",
                "kind"         to "weight",
                "deviceFamily" to "icomon",
                "deviceType"   to "scale",
                "sdk"          to "icomon",
                "mac"          to (device.macAddr ?: ""),
                "userId"       to data.userId,
                // `time` is a Unix timestamp in seconds.
                "time"         to data.time,
                "weight_kg"    to data.weight_kg,
                "weight_g"     to data.weight_g,
                "weight_lb"    to data.weight_lb,
                "weight_st"    to data.weight_st,
                "weight_st_lb" to data.weight_st_lb,
                "precision_kg" to data.precision_kg,
                "precision_lb" to data.precision_lb,
                "impedance"    to data.imp,
            ))
        }

        override fun onReceiveKitchenScaleHistoryData(
            device: ICDevice?,
            list: List<ICKitchenScaleData>?,
        ) {
            if (device == null || list == null) return
            for (entry in list) {
                sendEvent(mapOf(
                    "event"        to "historyData",
                    "kind"         to "kitchenScale",
                    "deviceFamily" to "icomon",
                    "deviceType"   to "scale",
                    "sdk"          to "icomon",
                    "mac"          to (device.macAddr ?: ""),
                    "weight_g"     to entry.value_g,
                    "isStabilized" to entry.isStabilized,
                ))
            }
        }

        override fun onReceiveRulerHistoryData(
            device: ICDevice?,
            data: ICRulerData?,
        ) {
            if (device == null || data == null) return
            sendEvent(mapOf(
                "event"        to "historyData",
                "kind"         to "ruler",
                "deviceFamily" to "icomon",
                "deviceType"   to "ruler",
                "sdk"          to "icomon",
                "mac"          to (device.macAddr ?: ""),
                "time"         to data.time,
                "distance_cm"  to data.distance_cm,
                "distance_in"  to data.distance_in,
                "distance_ft"  to data.distance_ft,
                "isStabilized" to data.isStabilized,
            ))
        }

        override fun onReceiveHistorySkipData(
            device: ICDevice?,
            data: ICSkipData?,
        ) {
            if (device == null || data == null) return
            sendEvent(mapOf(
                "event"         to "historyData",
                "kind"          to "skip",
                "deviceFamily"  to "icomon",
                "deviceType"    to "skip",
                "sdk"           to "icomon",
                "mac"           to (device.macAddr ?: ""),
                "time"          to data.time,
                "skipCount"     to data.skip_count,
                "elapsedTime"   to data.elapsed_time,
                "actualTime"    to data.actual_time,
                "avgFreq"       to data.avg_freq,
                "fastestFreq"   to data.fastest_freq,
                "calories"      to data.calories_burned,
                "interrupts"    to data.interrupts,
                "mostJump"      to data.most_jump,
                "battery"       to data.battery,
            ))
        }

        // Unit-changed reflections — fired when the user pressed the
        // unit button on the device, or when our setX wrapper took
        // effect. Mirrors the iOS scaleUnitChanged emitter.
        override fun onReceiveWeightUnitChanged(
            device: ICDevice?,
            unit: ICConstant.ICWeightUnit?,
        ) {
            if (device == null || unit == null) return
            sendEvent(mapOf(
                "event"    to "scaleUnitChanged",
                "subEvent" to "weight",
                "mac"      to (device.macAddr ?: ""),
                "unit"     to unit.ordinal,
            ))
        }

        override fun onReceiveRulerUnitChanged(
            device: ICDevice?,
            unit: ICConstant.ICRulerUnit?,
        ) {
            if (device == null || unit == null) return
            sendEvent(mapOf(
                "event"    to "scaleUnitChanged",
                "subEvent" to "ruler",
                "mac"      to (device.macAddr ?: ""),
                // re-shift to wire 1-indexed to match the Dart enum
                "unit"     to (unit.ordinal + 1),
            ))
        }

        override fun onReceiveKitchenScaleUnitChanged(
            device: ICDevice?,
            unit: ICConstant.ICKitchenScaleUnit?,
        ) {
            if (device == null || unit == null) return
            sendEvent(mapOf(
                "event"    to "scaleUnitChanged",
                "subEvent" to "kitchen",
                "mac"      to (device.macAddr ?: ""),
                "unit"     to unit.ordinal,
            ))
        }

        // Device-stored user profile push-back. Combines the device
        // identity with the profile dictionary so a Dart consumer can
        // call `ScaleUserProfile.fromMap(event)` directly.
        override fun onReceiveUserInfo(device: ICDevice?, userInfo: ICUserInfo?) {
            if (device == null || userInfo == null) return
            val evt = mutableMapOf<String, Any?>(
                "event"        to "scaleUserInfo",
                "deviceFamily" to "icomon",
                "mac"          to (device.macAddr ?: ""),
            )
            evt.putAll(mapFromIcUserInfo(userInfo))
            sendEvent(evt)
        }

        override fun onReceiveUserInfoList(
            device: ICDevice?,
            list: List<ICUserInfo>?,
        ) {
            if (device == null) return
            sendEvent(mapOf(
                "event"        to "scaleUserList",
                "deviceFamily" to "icomon",
                "mac"          to (device.macAddr ?: ""),
                "profiles"     to (list?.map { mapFromIcUserInfo(it) } ?: emptyList()),
            ))
        }
    }

    // ── All supported device models ─────────────────────────────────────
    private val allModels = intArrayOf(
        // ECG — ER1 family
        Bluetooth.MODEL_ER1, Bluetooth.MODEL_ER1_N, Bluetooth.MODEL_HHM1,
        Bluetooth.MODEL_ER1S, Bluetooth.MODEL_ER1_S, Bluetooth.MODEL_ER1_H,
        Bluetooth.MODEL_ER1_W, Bluetooth.MODEL_ER1_L,
        // ECG — ER2 family
        Bluetooth.MODEL_ER2, Bluetooth.MODEL_LP_ER2, Bluetooth.MODEL_DUOEK,
        Bluetooth.MODEL_LEPU_ER2, Bluetooth.MODEL_HHM2, Bluetooth.MODEL_HHM3,
        Bluetooth.MODEL_ER2_S,
        // ECG — ER3
        Bluetooth.MODEL_ER3, Bluetooth.MODEL_M12,
        // Oximeter — O2Ring family
        Bluetooth.MODEL_O2RING, Bluetooth.MODEL_O2M, Bluetooth.MODEL_BABYO2,
        Bluetooth.MODEL_BABYO2N, Bluetooth.MODEL_CHECKO2, Bluetooth.MODEL_SLEEPO2,
        Bluetooth.MODEL_SNOREO2, Bluetooth.MODEL_WEARO2, Bluetooth.MODEL_SLEEPU,
        Bluetooth.MODEL_OXYLINK, Bluetooth.MODEL_KIDSO2, Bluetooth.MODEL_OXYFIT,
        Bluetooth.MODEL_OXYRING, Bluetooth.MODEL_BBSM_S1, Bluetooth.MODEL_BBSM_S2,
        Bluetooth.MODEL_OXYU, Bluetooth.MODEL_AI_S100, Bluetooth.MODEL_O2M_WPS,
        Bluetooth.MODEL_CMRING, Bluetooth.MODEL_OXYFIT_WPS, Bluetooth.MODEL_KIDSO2_WPS,
        Bluetooth.MODEL_BBSM_S3, Bluetooth.MODEL_O2RING_RE, Bluetooth.MODEL_O2RINGF,
        // Oximeter — PC60FW/PF10 family
        Bluetooth.MODEL_PC60FW, Bluetooth.MODEL_PC_60NW, Bluetooth.MODEL_PC_60NW_1,
        Bluetooth.MODEL_PC66B, Bluetooth.MODEL_PF_10, Bluetooth.MODEL_PF_20,
        Bluetooth.MODEL_OXYSMART, Bluetooth.MODEL_POD2B, Bluetooth.MODEL_POD_1W,
        Bluetooth.MODEL_S5W, Bluetooth.MODEL_PF_10AW, Bluetooth.MODEL_PF_10AW1,
        Bluetooth.MODEL_PF_10BW, Bluetooth.MODEL_PF_10BW1, Bluetooth.MODEL_PF_20AW,
        Bluetooth.MODEL_PF_20B, Bluetooth.MODEL_S7W, Bluetooth.MODEL_S7BW,
        Bluetooth.MODEL_S6W, Bluetooth.MODEL_S6W1, Bluetooth.MODEL_PC60NW_BLE,
        Bluetooth.MODEL_PC60NW_WPS, Bluetooth.MODEL_PC_60NW_NO_SN,
        // Oximeter — PF10AW1/PF10BWS family
        Bluetooth.MODEL_PF_10AW_1, Bluetooth.MODEL_PF_10BWS,
        Bluetooth.MODEL_SA10AW_PU, Bluetooth.MODEL_PF10BW_VE,
        // OxyII family
        Bluetooth.MODEL_O2RING_S, Bluetooth.MODEL_S8_AW,
        Bluetooth.MODEL_BAND_WU, Bluetooth.MODEL_SHQO2_PRO,
        // BP — BP2 family
        Bluetooth.MODEL_BP2, Bluetooth.MODEL_BP2A, Bluetooth.MODEL_BP2T,
        Bluetooth.MODEL_BP2W, Bluetooth.MODEL_LP_BP2W,
        // BP — BP3 family
        Bluetooth.MODEL_BP3A, Bluetooth.MODEL_BP3B, Bluetooth.MODEL_BP3C,
        Bluetooth.MODEL_BP3D, Bluetooth.MODEL_BP3E, Bluetooth.MODEL_BP3F,
        Bluetooth.MODEL_BP3G, Bluetooth.MODEL_BP3H, Bluetooth.MODEL_BP3K,
        Bluetooth.MODEL_BP3L, Bluetooth.MODEL_BP3Z,
        // BP — others
        Bluetooth.MODEL_BPM, Bluetooth.MODEL_AIRBP,
        // PC80B
        Bluetooth.MODEL_PC80B, Bluetooth.MODEL_PC80B_BLE, Bluetooth.MODEL_PC80B_BLE2,
        // PC100
        Bluetooth.MODEL_PC100,
        // AP20
        Bluetooth.MODEL_AP20, Bluetooth.MODEL_AP20_WPS,
        // SP20
        Bluetooth.MODEL_SP20, Bluetooth.MODEL_SP20_BLE, Bluetooth.MODEL_SP20_WPS,
        // PC68B
        Bluetooth.MODEL_PC_68B,
        // PulsebitEX
        Bluetooth.MODEL_PULSEBITEX, Bluetooth.MODEL_HHM4,
        // CheckMe
        Bluetooth.MODEL_CHECKME, Bluetooth.MODEL_CHECKME_LE,
        Bluetooth.MODEL_CHECK_POD, Bluetooth.MODEL_CHECKME_POD_WPS,
        Bluetooth.MODEL_VETCORDER, Bluetooth.MODEL_CHECK_ADV,
        // PC303
        Bluetooth.MODEL_PC300, Bluetooth.MODEL_PC300_BLE,
        Bluetooth.MODEL_GM_300SNT, Bluetooth.MODEL_GM_300SNT_BLE,
        Bluetooth.MODEL_CMI_PC303,
        // Others
        Bluetooth.MODEL_TV221U, Bluetooth.MODEL_AOJ20A,
        Bluetooth.MODEL_BIOLAND_BGM, Bluetooth.MODEL_POCTOR_M3102,
        Bluetooth.MODEL_LPM311, Bluetooth.MODEL_LEM, Bluetooth.MODEL_ECN,
        Bluetooth.MODEL_LEPOD, Bluetooth.MODEL_LEPOD_PRO,
        Bluetooth.MODEL_R20, Bluetooth.MODEL_R21, Bluetooth.MODEL_R10,
        Bluetooth.MODEL_R11, Bluetooth.MODEL_LERES,
        Bluetooth.MODEL_FHR, Bluetooth.MODEL_VTM_AD5, Bluetooth.MODEL_FETAL,
        Bluetooth.MODEL_VCOMIN, Bluetooth.MODEL_BBSM_BS1,
    )

    // ════════════════════════════════════════════════════════════════════
    // FlutterPlugin lifecycle
    // ════════════════════════════════════════════════════════════════════

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        context = null
    }

    // ════════════════════════════════════════════════════════════════════
    // ActivityAware
    // ════════════════════════════════════════════════════════════════════

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }

    // ════════════════════════════════════════════════════════════════════
    // MethodChannel handler
    // ════════════════════════════════════════════════════════════════════

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initService"       -> handleInitService(result)
            "checkPermissions"  -> handleCheckPermissions(result)
            "requestPermissions"-> handleRequestPermissions(result)
            "getPermissionState"-> handleGetPermissionState(result)
            "scan"              -> handleStartScan(call, result)
            "stopScan"          -> handleStopScan(result)
            "connect"           -> handleConnect(call, result)
            "connectKnown"      -> handleConnectKnown(call, result)
            "disconnect"        -> handleDisconnect(result)
            "syncTime"          -> handleSyncTime(call, result)
            "getBattery"        -> handleGetBattery(call, result)
            "getDeviceConfig"   -> handleGetDeviceConfig(call, result)
            "setDeviceConfig"   -> handleSetDeviceConfig(call, result)
            "startMeasurement"  -> handleStartMeasurement(call, result)
            "stopMeasurement"   -> handleStopMeasurement(call, result)
            "getDeviceInfo"     -> handleGetDeviceInfo(call, result)
            "getFileList"       -> handleGetFileList(call, result)
            "readFile"          -> handleReadFile(call, result)
            "cancelReadFile"    -> handleCancelReadFile(call, result)
            "pauseReadFile"     -> handlePauseReadFile(call, result)
            "continueReadFile"  -> handleContinueReadFile(call, result)
            "readHistoryData"   -> handleReadHistoryData(result)
            "factoryReset"      -> handleFactoryReset(call, result)
            "shutdown"          -> handleShutdown(call, result)
            "updateUserInfo"    -> handleUpdateUserInfo(call, result)
            "setScaleUserProfile" -> handleSetScaleUserProfile(call, result)
            "setScaleUserList"  -> handleSetScaleUserList(call, result)
            "setScaleWeightUnit"-> handleSetScaleWeightUnit(call, result)
            "setScaleRulerUnit" -> handleSetScaleRulerUnit(call, result)
            "setKitchenScaleUnit"-> handleSetKitchenScaleUnit(call, result)
            "isServiceReady"    -> result.success(serviceInitialized)
            "getConnectedModel" -> result.success(connectedModel)
            else                -> result.notImplemented()
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Permission handling
    // ════════════════════════════════════════════════════════════════════

    private fun handleCheckPermissions(result: Result) {
        result.success(hasBluetoothPermissions())
    }

    /// Granular companion to [handleCheckPermissions]. Returns one of:
    ///   "granted"       — all required runtime permissions are granted
    ///                     AND Bluetooth is currently ON.
    ///   "denied"        — the user has revoked at least one permission
    ///                     and `shouldShowRequestPermissionRationale`
    ///                     returns false (permanent deny) → consumer
    ///                     should send them to app settings.
    ///   "poweredOff"    — permissions are fine but the Bluetooth radio
    ///                     is OFF; consumer should prompt to enable it.
    ///   "unsupported"   — the device has no BluetoothAdapter
    ///                     (extremely rare; emulator-only).
    ///   "notDetermined" — permissions not yet requested; the consumer
    ///                     should call `requestPermissions` first.
    private fun handleGetPermissionState(result: Result) {
        val ctx = context
        if (ctx == null) { result.success("notDetermined"); return }
        val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE)
            as? BluetoothManager)?.adapter
        if (adapter == null) { result.success("unsupported"); return }

        if (!hasBluetoothPermissions()) {
            val act = activity
            val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                Manifest.permission.BLUETOOTH_CONNECT
            else
                Manifest.permission.ACCESS_FINE_LOCATION
            val rationale = act != null &&
                ActivityCompat.shouldShowRequestPermissionRationale(act, perm)
            // First-launch (rationale==false AND no activity context)
            // and "don't-ask-again" both surface as rationale==false.
            // We disambiguate by checking whether ANY of the relevant
            // perms is in the "previously requested at least once"
            // state via `checkSelfPermission` returning DENIED — which
            // happens only after the user has actively dismissed.
            val anyRequested = ContextCompat.checkSelfPermission(
                ctx, perm
            ) == PackageManager.PERMISSION_DENIED && act != null && !rationale
            result.success(if (anyRequested) "denied" else "notDetermined")
            return
        }

        if (!adapter.isEnabled) { result.success("poweredOff"); return }
        result.success("granted")
    }

    private fun handleRequestPermissions(result: Result) {
        if (hasBluetoothPermissions()) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No activity to request permissions", null)
            return
        }
        pendingPermissionResult = result
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }
        ActivityCompat.requestPermissions(act, permissions, PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val allGranted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(allGranted)
        pendingPermissionResult = null
        return true
    }

    private fun hasBluetoothPermissions(): Boolean {
        val ctx = context ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // BLE Service init
    // ════════════════════════════════════════════════════════════════════

    private fun handleInitService(result: Result) {
        val ctx = context ?: run {
            result.error("NO_CONTEXT", "Application context is null", null)
            return
        }
        try {
            if (!serviceInitialized) {
                val app = ctx.applicationContext as Application
                registerLiveEventBus()
                BleServiceHelper.BleServiceHelper.initService(app).initLog(true)
                
                // Initialize iComon SDK
                val config = ICDeviceManagerConfig().apply {
                    context = app
                }
                val userInfo = ICUserInfo().apply {
                    age = 25
                    height = 175
                    sex = ICConstant.ICSexType.ICSexTypeMale
                    peopleType = ICConstant.ICPeopleType.ICPeopleTypeNormal
                }
                ICDeviceManager.shared().setDelegate(iComonDeviceDelegate)
                ICDeviceManager.shared().updateUserInfo(userInfo)
                ICDeviceManager.shared().initMgrWithConfig(config)

                serviceInitialized = true
            } else {
                // If already initialized, manually trigger serviceReady to unblock UI
                sendEvent(mapOf("event" to "serviceReady"))
            }
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "initService failed", e)
            result.error("INIT_FAILED", e.message, null)
        }
    }

    private fun handleUpdateUserInfo(call: MethodCall, result: Result) {
        val height = call.argument<Double>("height") ?: 170.0
        val age = call.argument<Int>("age") ?: 25
        val isMale = call.argument<Boolean>("isMale") ?: true

        val userInfo = ICUserInfo().apply {
            this.age = age
            this.height = height.toInt()
            this.sex = if (isMale) ICConstant.ICSexType.ICSexTypeMale else ICConstant.ICSexType.ICSexTypeFemal
            this.peopleType = ICConstant.ICPeopleType.ICPeopleTypeNormal
        }
        ICDeviceManager.shared().updateUserInfo(userInfo)
        result.success(true)
    }

    // Translate the Dart wire map (mirror of `ScaleUserProfile.toMap()`)
    // to an `ICUserInfo`. The integer enums on the wire match the
    // raw `ordinal()` of the corresponding ICConstant enum, so we can
    // look them up via `values()[i]` after a bounds check.
    @Suppress("UNCHECKED_CAST")
    private fun icUserInfoFromMap(m: Map<String, Any?>): ICUserInfo {
        fun <T : Enum<T>> safe(arr: Array<T>, idx: Int, default: T): T =
            if (idx in arr.indices) arr[idx] else default

        val info = ICUserInfo()
        info.userIndex   = (m["userIndex"] as? Number)?.toInt() ?: 1
        info.userId      = (m["userId"] as? Number)?.toLong() ?: 0L
        (m["nickName"] as? String)?.let { info.nickName = it }
        info.height      = (m["heightCm"] as? Number)?.toInt() ?: 170
        info.age         = (m["age"] as? Number)?.toInt() ?: 25
        info.sex         = safe(
            ICConstant.ICSexType.values(),
            (m["sex"] as? Number)?.toInt() ?: 1,
            ICConstant.ICSexType.ICSexTypeMale,
        )
        info.weight      = (m["lastWeightKg"] as? Number)?.toDouble() ?: 60.0
        info.peopleType  = safe(
            ICConstant.ICPeopleType.values(),
            (m["peopleType"] as? Number)?.toInt() ?: 0,
            ICConstant.ICPeopleType.ICPeopleTypeNormal,
        )
        info.weightUnit  = safe(
            ICConstant.ICWeightUnit.values(),
            (m["weightUnit"] as? Number)?.toInt() ?: 0,
            ICConstant.ICWeightUnit.ICWeightUnitKg,
        )
        info.rulerUnit   = safe(
            ICConstant.ICRulerUnit.values(),
            ((m["rulerUnit"] as? Number)?.toInt() ?: 1) - 1, // wire is 1-indexed
            ICConstant.ICRulerUnit.ICRulerUnitCM,
        )
        info.kitchenUnit = safe(
            ICConstant.ICKitchenScaleUnit.values(),
            (m["kitchenUnit"] as? Number)?.toInt() ?: 0,
            ICConstant.ICKitchenScaleUnit.ICKitchenScaleUnitG,
        )
        info.enableMeasureImpendence = (m["enableImpedance"] as? Boolean) ?: true
        info.enableMeasureHr         = (m["enableHeartRate"] as? Boolean) ?: true
        info.enableMeasureBalance    = (m["enableBalance"] as? Boolean) ?: true
        info.enableMeasureGravity    = (m["enableGravity"] as? Boolean) ?: true
        return info
    }

    // Reverse mapping for events emitted back to Dart.
    private fun mapFromIcUserInfo(u: ICUserInfo): Map<String, Any?> = mapOf(
        "userIndex"       to u.userIndex,
        "userId"          to u.userId,
        "nickName"        to u.nickName,
        "heightCm"        to u.height,
        "age"             to u.age,
        "sex"             to u.sex.ordinal,
        "lastWeightKg"    to u.weight.toDouble(),
        "peopleType"      to u.peopleType.ordinal,
        "weightUnit"      to u.weightUnit.ordinal,
        "rulerUnit"       to (u.rulerUnit.ordinal + 1), // re-shift to wire 1-indexed
        "kitchenUnit"     to u.kitchenUnit.ordinal,
        "enableImpedance" to u.enableMeasureImpendence,
        "enableHeartRate" to u.enableMeasureHr,
        "enableBalance"   to u.enableMeasureBalance,
        "enableGravity"   to u.enableMeasureGravity,
    )

    private fun handleSetScaleUserProfile(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<String, Any?>
        if (args == null) {
            result.error("BAD_ARG", "setScaleUserProfile expects a Map payload", null)
            return
        }
        val info = icUserInfoFromMap(args)
        ICDeviceManager.shared().updateUserInfo(info)
        result.success(true)
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleSetScaleUserList(call: MethodCall, result: Result) {
        val raw = call.argument<List<Map<String, Any?>>>("profiles")
        if (raw == null) {
            result.error("BAD_ARG", "setScaleUserList expects {profiles: [...]} payload", null)
            return
        }
        val list = raw.map { icUserInfoFromMap(it) }
        ICDeviceManager.shared().setUserList(list)
        val dev = activeIComonDevice
        if (dev != null) {
            try {
                ICDeviceManager.shared().settingManager
                    .setUserList(dev, list) { code ->
                        Log.d(TAG, "iComon setUserList per-device code=$code")
                    }
            } catch (e: Exception) {
                Log.w(TAG, "iComon setUserList per-device failed: ${e.message}")
            }
        }
        result.success(true)
    }

    private fun handleSetScaleWeightUnit(call: MethodCall, result: Result) {
        val dev = activeIComonDevice
            ?: return result.error("NOT_CONNECTED", "No iComon scale connected", null)
        val idx = call.argument<Int>("unit")
            ?: return result.error("BAD_ARG", "setScaleWeightUnit requires {unit: int}", null)
        val unit = ICConstant.ICWeightUnit.values().getOrNull(idx)
            ?: ICConstant.ICWeightUnit.ICWeightUnitKg
        try {
            ICDeviceManager.shared().settingManager
                .setScaleUnit(dev, unit) { code ->
                    Log.d(TAG, "setScaleUnit code=$code")
                }
            result.success(true)
        } catch (e: Exception) {
            result.error("SET_UNIT_FAILED", e.message, null)
        }
    }

    private fun handleSetScaleRulerUnit(call: MethodCall, result: Result) {
        val dev = activeIComonDevice
            ?: return result.error("NOT_CONNECTED", "No iComon ruler connected", null)
        val wire = call.argument<Int>("unit")
            ?: return result.error("BAD_ARG", "setScaleRulerUnit requires {unit: int}", null)
        val unit = ICConstant.ICRulerUnit.values().getOrNull(wire - 1) // wire is 1-indexed
            ?: ICConstant.ICRulerUnit.ICRulerUnitCM
        try {
            ICDeviceManager.shared().settingManager
                .setRulerUnit(dev, unit) { code ->
                    Log.d(TAG, "setRulerUnit code=$code")
                }
            result.success(true)
        } catch (e: Exception) {
            result.error("SET_UNIT_FAILED", e.message, null)
        }
    }

    private fun handleSetKitchenScaleUnit(call: MethodCall, result: Result) {
        val dev = activeIComonDevice
            ?: return result.error("NOT_CONNECTED", "No iComon kitchen scale connected", null)
        val idx = call.argument<Int>("unit")
            ?: return result.error("BAD_ARG", "setKitchenScaleUnit requires {unit: int}", null)
        val unit = ICConstant.ICKitchenScaleUnit.values().getOrNull(idx)
            ?: ICConstant.ICKitchenScaleUnit.ICKitchenScaleUnitG
        try {
            ICDeviceManager.shared().settingManager
                .setKitchenScaleUnit(dev, unit) { code ->
                    Log.d(TAG, "setKitchenScaleUnit code=$code")
                }
            result.success(true)
        } catch (e: Exception) {
            result.error("SET_UNIT_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Scanning
    // ════════════════════════════════════════════════════════════════════

    private fun handleStartScan(call: MethodCall, result: Result) {
        if (!serviceInitialized) {
            result.error("NOT_INITIALIZED", "Call initService first", null)
            return
        }
        if (!hasBluetoothPermissions()) {
            result.error("NO_PERMISSION", "Bluetooth permissions not granted", null)
            return
        }
        try {
            val modelList = call.argument<List<Int>>("models")
            val models = modelList?.toIntArray() ?: allModels
            BluetoothController.clear()
            BleServiceHelper.BleServiceHelper.startScan(models)
            ICDeviceManager.shared().scanDevice(iComonScanDelegate)
            result.success(true)
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException during scan", e)
            result.error("SECURITY_EXCEPTION", "BLE scan denied: ${e.message}", null)
        } catch (e: Exception) {
            Log.e(TAG, "Scan failed", e)
            result.error("SCAN_FAILED", e.message, null)
        }
    }

    private fun handleStopScan(result: Result) {
        try {
            BleServiceHelper.BleServiceHelper.stopScan()
            ICDeviceManager.shared().stopScan()
            result.success(true)
        } catch (e: Exception) {
            result.error("STOP_SCAN_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Connection
    // ════════════════════════════════════════════════════════════════════

    private fun handleConnect(call: MethodCall, result: Result) {
        val ctx = context ?: run {
            result.error("NO_CONTEXT", "Context is null", null)
            return
        }

        val mac = call.argument<String>("mac") ?: run {
            result.error("INVALID_ARGS", "mac is required", null)
            return
        }
        val sdk = call.argument<String>("sdk") ?: "lepu"
        // Connect-time options — default to eager catch-up on recording
        // finish. Consumers can opt out by passing autoFetchOnFinish=false
        // e.g. if they want purely manual history control.
        autoFetchOnFinish = call.argument<Boolean>("autoFetchOnFinish") ?: true

        if (sdk == "icomon") {
            try {
                val icDevice = ICDevice()
                icDevice.macAddr = mac
                activeIComonDevice = icDevice
                ICDeviceManager.shared().addDevice(icDevice) { _, code ->
                    Log.d(TAG, "iComon addDevice result: $code")
                }
                result.success(true)
            } catch (e: Exception) {
                activeIComonDevice = null
                result.error("CONNECT_FAILED", e.message, null)
            }
            return
        }

        // Lepu logic
        val model = call.argument<Int>("model")
        if (model == null) {
            result.error("INVALID_ARGS", "model is required for lepu", null)
            return
        }

        try {
            val devices = BluetoothController.getDevices()
            var target: Bluetooth? = null
            for (d in devices) {
                if (d.macAddr.equals(mac, ignoreCase = true)) {
                    target = d
                    break
                }
            }

            if (target != null) {
                // Device is in scan cache — connect directly
                BleServiceHelper.BleServiceHelper.setInterfaces(model)
                BleServiceHelper.BleServiceHelper.connect(ctx.applicationContext, model, target.device)
                connectedModel = model
                result.success(true)
            } else {
                // Device not in scan cache — start a quick scan to find it
                Log.d(TAG, "Device $mac not in scan cache, starting quick scan...")
                BleServiceHelper.BleServiceHelper.setInterfaces(model)
                BluetoothController.clear()
                BleServiceHelper.BleServiceHelper.startScan(intArrayOf(model))

                // Observe scan results and connect when found
                val handler = Handler(Looper.getMainLooper())
                var found = false
                val scanObserver = object : androidx.lifecycle.Observer<Bluetooth> {
                    override fun onChanged(bt: Bluetooth) {
                        if (!found) {
                            val scanned = BluetoothController.getDevices()
                            for (d in scanned) {
                                if (d.macAddr.equals(mac, ignoreCase = true)) {
                                    found = true
                                    BleServiceHelper.BleServiceHelper.stopScan()
                                    LiveEventBus.get<Bluetooth>(EventMsgConst.Discovery.EventDeviceFound)
                                        .removeObserver(this)
                                    BleServiceHelper.BleServiceHelper.connect(ctx.applicationContext, model, d.device)
                                    connectedModel = model
                                    Log.d(TAG, "Found $mac in scan, connecting...")
                                    break
                                }
                            }
                        }
                    }
                }
                LiveEventBus.get<Bluetooth>(EventMsgConst.Discovery.EventDeviceFound)
                    .observeForever(scanObserver)

                // Timeout: stop scanning after 10s
                handler.postDelayed({
                    if (!found) {
                        found = true // so we don't process further results
                        BleServiceHelper.BleServiceHelper.stopScan()
                        LiveEventBus.get<Bluetooth>(EventMsgConst.Discovery.EventDeviceFound)
                            .removeObserver(scanObserver)
                        Log.w(TAG, "Quick scan timed out for $mac")
                    }
                }, 10000)

                result.success(true)
            }
        } catch (e: SecurityException) {
            result.error("SECURITY_EXCEPTION", "BLE connect denied: ${e.message}", null)
        } catch (e: Exception) {
            result.error("CONNECT_FAILED", e.message, null)
        }
    }

    private fun handleDisconnect(result: Result) {
        try {
            BleServiceHelper.BleServiceHelper.stopScan()
            BleServiceHelper.BleServiceHelper.disconnect(false)
            // Also release any bound iComon scale — the iComon SDK keeps
            // an internal BLE session until removeDevice is invoked.
            activeIComonDevice?.let { dev ->
                try {
                    ICDeviceManager.shared().removeDevice(dev) { _, _ -> }
                } catch (e: Exception) {
                    Log.w(TAG, "iComon removeDevice failed: ${e.message}")
                }
            }
            activeIComonDevice = null
            connectedModel = -1
            knownFilesByModel.clear()
            pendingCatchUpByModel.clear()
            lastReadFileNameByModel.clear()
            lastEr1CurStatus = -1
            lastEr2CurStatus = -1
            lastBp2MeasureType = ""
            bp2aAutoStartPending = false
            result.success(true)
        } catch (e: Exception) {
            result.error("DISCONNECT_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // iComon scale history — "all stored measurements" pull
    // ════════════════════════════════════════════════════════════════════
    //
    // Welland-family body-composition scales (and the related kitchen /
    // ruler / jump-rope devices) buffer measurements taken while the
    // phone was out of range. When the phone reconnects, those records
    // are replayed through the `onReceiveWeightHistoryData` /
    // `onReceiveKitchenScaleHistoryData` / `onReceiveRulerHistoryData` /
    // `onReceiveHistorySkipData` callbacks — which this plugin forwards
    // as `historyData` events.
    //
    // `readHistoryData` asks the scale to replay every stored record on
    // demand (rather than only the ones uploaded automatically on
    // reconnect). Not every firmware supports it — `onReceiveDeviceInfo`
    // carries `isSupportHistoryData` for a runtime check.
    private fun handleReadHistoryData(result: Result) {
        val device = activeIComonDevice ?: run {
            result.error(
                "UNSUPPORTED",
                "readHistoryData is iComon-scale only; connect with sdk='icomon' first",
                null,
            )
            return
        }
        try {
            // ICSettingCallback.onCallBack is a single-arg interface in
            // ICDeviceManager.aar (`onCallBack(ICSettingCallBackCode)`).
            // The lambda has the same arity.
            ICDeviceManager.shared().settingManager
                .readHistoryData(device) { code ->
                    Log.d(TAG, "iComon readHistoryData returned code=$code")
                }
            result.success(true)
        } catch (e: Throwable) {
            result.error("READ_HISTORY_FAILED", e.message ?: "readHistoryData failed", null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Direct-connect by known MAC (no fresh scan required)
    //
    // Symmetric with iOS's `connectKnown` — uses BluetoothAdapter.getRemoteDevice
    // which works for any previously-bonded device the OS still remembers.
    // If the lookup misses (fresh install, BT cache cleared, device out of
    // range), falls through to the same quick-rescan fallback `handleConnect`
    // already uses from its cache-empty branch.
    // ════════════════════════════════════════════════════════════════════

    private fun handleConnectKnown(call: MethodCall, result: Result) {
        val ctx = context ?: run {
            result.error("NO_CONTEXT", "Context is null", null)
            return
        }
        val sdk = call.argument<String>("sdk") ?: "lepu"
        if (sdk == "icomon") {
            // iComon's addDevice already operates by MAC string with no
            // discovery needed — same flow as the standard connect path.
            handleConnect(call, result)
            return
        }

        val mac = call.argument<String>("mac") ?: run {
            result.error("INVALID_ARGS", "mac is required", null); return
        }
        val model = call.argument<Int>("model") ?: run {
            result.error("INVALID_ARGS", "model is required for connectKnown(sdk:lepu)", null)
            return
        }
        autoFetchOnFinish = call.argument<Boolean>("autoFetchOnFinish") ?: true

        try {
            // BluetoothAdapter.getRemoteDevice never returns null for a
            // valid MAC string — but it throws IllegalArgumentException on
            // a malformed one (lower-case letters, missing colons, …). We
            // surface that as INVALID_ARGS so the consumer can fix the
            // argument rather than blaming the SDK.
            val adapter: BluetoothAdapter? = (ctx.getSystemService(Context.BLUETOOTH_SERVICE)
                    as? BluetoothManager)?.adapter
            if (adapter == null) {
                result.error("UNSUPPORTED", "Bluetooth is not available on this device", null)
                return
            }
            val remote = try {
                adapter.getRemoteDevice(mac.uppercase())
            } catch (e: IllegalArgumentException) {
                result.error("INVALID_ARGS",
                    "mac is not a valid Bluetooth address: ${e.message}", null)
                return
            }

            BleServiceHelper.BleServiceHelper.setInterfaces(model)
            BleServiceHelper.BleServiceHelper.connect(
                ctx.applicationContext, model, remote
            )
            connectedModel = model
            Log.d(TAG, "connectKnown direct-connect mac=$mac model=$model")
            result.success(true)
        } catch (e: SecurityException) {
            result.error("SECURITY_EXCEPTION", "BLE connect denied: ${e.message}", null)
        } catch (e: Exception) {
            // Fall back to the rescan-and-connect path on any other error
            // (e.g. some OEMs throw on `connect()` for an unbonded device).
            Log.w(TAG, "connectKnown direct-connect failed (${e.message}); falling back to rescan")
            handleConnect(call, result)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Time sync — push phone time to the device
    //
    // `BleServiceHelper.syncTime(model)` always uses the system clock —
    // the `time` argument from Dart is therefore ignored on Android.
    // (Lepu's helper has no overload to inject an explicit timestamp.)
    // The audit doc calls this out explicitly so the Dart docstring
    // reflects the asymmetry.
    // ════════════════════════════════════════════════════════════════════

    private fun handleSyncTime(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            BleServiceHelper.BleServiceHelper.syncTime(model)
            result.success(true)
        } catch (e: Exception) {
            result.error("SYNC_TIME_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Battery query — on-demand
    //
    // The Lepu SDK only exposes a dedicated battery-query call for the
    // AirBP / AP20 / SP20 / LEM / OxyII / PC80B / BP3 families. For the
    // bigger ER1/ER2/BP2/Oxy/PF10AW1 families battery ships as a side-
    // effect of `startRtTask` — so consumers on those families should
    // call `startMeasurement` and observe `batteryStream` for the
    // value carried inside every rtData packet.
    // ════════════════════════════════════════════════════════════════════

    private fun handleGetBattery(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (configFamilyForModel(model)) {
                ConfigFamily.OXYII -> BleServiceHelper.BleServiceHelper.oxyIIGetBattery(model)
                ConfigFamily.BP3   -> BleServiceHelper.BleServiceHelper.bp3GetInfo(model)
                ConfigFamily.AIRBP -> BleServiceHelper.BleServiceHelper.airBpGetBattery(model)
                ConfigFamily.NONE,
                ConfigFamily.BP2,
                ConfigFamily.ER1,
                ConfigFamily.ER2,
                ConfigFamily.OXY,
                ConfigFamily.PF10AW1 -> {
                    result.error(
                        "UNSUPPORTED",
                        "Model $model has no dedicated battery query on Android. " +
                            "Start a measurement and read battery from the rtData/batteryStream events.",
                        mapOf("model" to model),
                    )
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("GET_BATTERY_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Device configuration — read / write
    //
    // Per family the Lepu SDK uses a different struct shape, so we route
    // by family and emit a stable `deviceConfig` event with family-
    // specific fields. The Dart `DeviceConfigEvent.fields` map preserves
    // these names verbatim — see lib/src/models/device_control.dart.
    // ════════════════════════════════════════════════════════════════════

    private enum class ConfigFamily { BP2, BP3, ER1, ER2, OXY, OXYII, PF10AW1, AIRBP, NONE }

    private fun configFamilyForModel(model: Int): ConfigFamily = when (model) {
        Bluetooth.MODEL_AIRBP -> ConfigFamily.AIRBP

        Bluetooth.MODEL_BP2, Bluetooth.MODEL_BP2A, Bluetooth.MODEL_BP2T -> ConfigFamily.BP2

        Bluetooth.MODEL_BP3A, Bluetooth.MODEL_BP3B, Bluetooth.MODEL_BP3C,
        Bluetooth.MODEL_BP3D, Bluetooth.MODEL_BP3E, Bluetooth.MODEL_BP3F,
        Bluetooth.MODEL_BP3G, Bluetooth.MODEL_BP3H, Bluetooth.MODEL_BP3K,
        Bluetooth.MODEL_BP3L, Bluetooth.MODEL_BP3Z -> ConfigFamily.BP3

        Bluetooth.MODEL_ER1, Bluetooth.MODEL_ER1_N, Bluetooth.MODEL_HHM1,
        Bluetooth.MODEL_ER1S, Bluetooth.MODEL_ER1_S, Bluetooth.MODEL_ER1_H,
        Bluetooth.MODEL_ER1_W, Bluetooth.MODEL_ER1_L -> ConfigFamily.ER1

        Bluetooth.MODEL_ER2, Bluetooth.MODEL_LP_ER2, Bluetooth.MODEL_DUOEK,
        Bluetooth.MODEL_LEPU_ER2, Bluetooth.MODEL_HHM2, Bluetooth.MODEL_HHM3,
        Bluetooth.MODEL_ER2_S -> ConfigFamily.ER2

        // Legacy O2Ring family — Lepu's SDK doesn't expose an explicit
        // config endpoint; settings ride along inside oxyUpdateSetting
        // which is keyed on a vendor enum. Treat as unsupported for the
        // generic getDeviceConfig API for now.
        Bluetooth.MODEL_O2RING, Bluetooth.MODEL_O2M, Bluetooth.MODEL_BABYO2,
        Bluetooth.MODEL_BABYO2N, Bluetooth.MODEL_CHECKO2, Bluetooth.MODEL_SLEEPO2,
        Bluetooth.MODEL_SNOREO2, Bluetooth.MODEL_WEARO2, Bluetooth.MODEL_SLEEPU,
        Bluetooth.MODEL_OXYLINK, Bluetooth.MODEL_KIDSO2, Bluetooth.MODEL_OXYFIT,
        Bluetooth.MODEL_OXYRING, Bluetooth.MODEL_BBSM_S1, Bluetooth.MODEL_BBSM_S2,
        Bluetooth.MODEL_OXYU, Bluetooth.MODEL_AI_S100 -> ConfigFamily.OXY

        // OxyII family ≡ iOS WOxi family. The Lepu SDK uses the
        // oxyII* methods (Config class lives in `com.lepu.blepro.ext.oxy2`).
        Bluetooth.MODEL_O2M_WPS, Bluetooth.MODEL_OXYFIT_WPS,
        Bluetooth.MODEL_KIDSO2_WPS, Bluetooth.MODEL_BBSM_S3,
        Bluetooth.MODEL_O2RING_RE, Bluetooth.MODEL_O2RINGF,
        Bluetooth.MODEL_CMRING -> ConfigFamily.OXYII

        Bluetooth.MODEL_PF_10AW_1, Bluetooth.MODEL_PF_10BWS,
        Bluetooth.MODEL_SA10AW_PU, Bluetooth.MODEL_PF10BW_VE -> ConfigFamily.PF10AW1

        else -> ConfigFamily.NONE
    }

    private fun handleGetDeviceConfig(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (configFamilyForModel(model)) {
                ConfigFamily.BP2     -> BleServiceHelper.BleServiceHelper.bp2GetConfig(model)
                ConfigFamily.BP3     -> BleServiceHelper.BleServiceHelper.bp3GetConfig(model)
                ConfigFamily.ER1     -> BleServiceHelper.BleServiceHelper.er1GetConfig(model)
                ConfigFamily.ER2     -> BleServiceHelper.BleServiceHelper.er2GetConfig(model)
                ConfigFamily.OXYII   -> BleServiceHelper.BleServiceHelper.oxyIIGetConfig(model)
                ConfigFamily.PF10AW1 -> BleServiceHelper.BleServiceHelper.pf10Aw1GetConfig(model)
                ConfigFamily.AIRBP   -> BleServiceHelper.BleServiceHelper.airBpGetConfig(model)
                ConfigFamily.OXY,
                ConfigFamily.NONE    -> {
                    result.error(
                        "UNSUPPORTED",
                        "Model $model does not expose a generic config endpoint on Android",
                        mapOf("model" to model),
                    )
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("GET_CONFIG_FAILED", e.message, null)
        }
    }

    private fun handleSetDeviceConfig(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        val fields = call.argument<List<Map<String, Any?>>>("fields") ?: emptyList()
        if (fields.isEmpty()) {
            result.error("INVALID_ARGS", "fields must be a non-empty list", null)
            return
        }
        // Index by name for O(1) lookup in the per-family builders below.
        val byName: Map<String, Any?> = fields.associate { f ->
            (f["name"] as? String ?: "") to f["value"]
        }
        try {
            when (configFamilyForModel(model)) {
                ConfigFamily.BP2     -> setBp2Config(model, byName, result)
                ConfigFamily.BP3     -> setBp3Config(model, byName, result)
                ConfigFamily.ER1     -> setEr1Config(model, byName, result)
                ConfigFamily.ER2     -> setEr2Config(model, byName, result)
                ConfigFamily.OXYII   -> setOxyIIConfig(model, byName, result)
                ConfigFamily.PF10AW1 -> setPf10Aw1Config(model, byName, result)
                ConfigFamily.AIRBP   -> setAirBpConfig(model, byName, result)
                ConfigFamily.OXY,
                ConfigFamily.NONE    -> {
                    result.error(
                        "UNSUPPORTED",
                        "setDeviceConfig is not wired for model $model on Android",
                        mapOf("model" to model),
                    )
                    return
                }
            }
        } catch (e: Exception) {
            result.error("SET_CONFIG_FAILED", e.message, null)
        }
    }

    // ── Per-family setConfig builders ───────────────────────────────────
    //
    // Each builder constructs the vendor's Kotlin config class, populates
    // only the fields the consumer supplied (preserving defaults for the
    // rest), and dispatches to the matching `BleServiceHelper.xxxSetConfig`.
    // Reflection is used for the Oxy2 nested-class fields so a missing
    // setter (vendor SDK update) doesn't crash the whole call.

    private fun setBp2Config(model: Int, fields: Map<String, Any?>, result: Result) {
        val cfg = com.lepu.blepro.ext.bp2.Bp2Config()
        (fields["soundOn"] as? Boolean)?.let { cfg.isSoundOn = it }
        BleServiceHelper.BleServiceHelper.bp2SetConfig(model, cfg)
        result.success(true)
    }

    private fun setBp3Config(model: Int, fields: Map<String, Any?>, result: Result) {
        val cfg = com.lepu.blepro.ext.bp3.Bp3Config()
        (fields["soundOn"] as? Boolean)?.let { cfg.isSoundOn = it }
        (fields["avgMeasureMode"] as? Int)?.let { cfg.avgMeasureMode = it }
        (fields["volume"] as? Int)?.let { cfg.volume = it }
        BleServiceHelper.BleServiceHelper.bp3SetConfig(model, cfg)
        result.success(true)
    }

    private fun setEr1Config(model: Int, fields: Map<String, Any?>, result: Result) {
        val cfg = com.lepu.blepro.ext.er1.Er1Config()
        (fields["vibration"] as? Boolean)?.let { cfg.isVibration = it }
        (fields["threshold1"] as? Int)?.let { cfg.threshold1 = it }
        (fields["threshold2"] as? Int)?.let { cfg.threshold2 = it }
        BleServiceHelper.BleServiceHelper.er1SetConfig(model, cfg)
        result.success(true)
    }

    private fun setEr2Config(model: Int, fields: Map<String, Any?>, result: Result) {
        val cfg = com.lepu.blepro.ext.er2.Er2Config()
        (fields["soundOn"] as? Boolean)?.let { cfg.isSoundOn = it }
        (fields["vector"] as? Int)?.let { cfg.vector = it }
        (fields["motionCount"] as? Int)?.let { cfg.motionCount = it }
        (fields["motionWindows"] as? Int)?.let { cfg.motionWindows = it }
        BleServiceHelper.BleServiceHelper.er2SetConfig(model, cfg)
        result.success(true)
    }

    private fun setPf10Aw1Config(model: Int, fields: Map<String, Any?>, result: Result) {
        (fields["spo2Low"] as? Int)?.let { BleServiceHelper.BleServiceHelper.pf10Aw1SetSpo2Low(model, it) }
        (fields["prHi"] as? Int ?: fields["prHigh"] as? Int)?.let { BleServiceHelper.BleServiceHelper.pf10Aw1SetPrHigh(model, it) }
        (fields["prLow"] as? Int)?.let { BleServiceHelper.BleServiceHelper.pf10Aw1SetPrLow(model, it) }
        (fields["alarmOn"] as? Boolean ?: fields["alarm"] as? Boolean)?.let { BleServiceHelper.BleServiceHelper.pf10Aw1SetAlarmSwitch(model, it) }
        (fields["beepOn"] as? Boolean ?: fields["beep"] as? Boolean)?.let { BleServiceHelper.BleServiceHelper.pf10Aw1SetBeepSwitch(model, it) }
        (fields["esMode"] as? Int)?.let { BleServiceHelper.BleServiceHelper.pf10Aw1SetEsMode(model, it) }
        result.success(true)
    }

    // AirBP / SmartBP — the SDK's `airBpSetConfig` takes a single bool
    // (sound-on). If a consumer passes `soundOn` that wins; otherwise
    // we look for the iOS-side `volume == 0` convention so a single
    // mute-everywhere call works on both platforms.
    private fun setAirBpConfig(model: Int, fields: Map<String, Any?>, result: Result) {
        val sound = fields["soundOn"] as? Boolean
            ?: (fields["volume"] as? Int)?.let { it > 0 }
            ?: true
        BleServiceHelper.BleServiceHelper.airBpSetConfig(model, sound)
        result.success(true)
    }

    // OxyII's `oxy2.Config` exposes one nested wrapper class per setting
    // (Spo2Switch/Spo2Low/HrSwitch/HrLow/HrHigh/Motor/Buzzer/DisplayMode/
    // BrightnessMode/StorageInterval), each with a single `val` u_int.
    // We allocate a wrapper for every field the consumer supplied so the
    // SDK ships a partial-update packet. Reflection keeps us tolerant of
    // SDK upgrades that rename a nested class.
    private fun setOxyIIConfig(model: Int, fields: Map<String, Any?>, result: Result) {
        val cfg = com.lepu.blepro.ext.oxy2.Config()
        fun assignNested(setterName: String, nestedClassSimpleName: String, value: Int) {
            try {
                val nested = Class.forName(
                    "com.lepu.blepro.ext.oxy2.Config\$$nestedClassSimpleName"
                )
                val wrapper = nested.getDeclaredConstructor().newInstance()
                // Each nested type has a single `setVal(int)` setter
                // (per the AAR's javap dump). Call it reflectively to
                // shield against a future field rename.
                val setVal = nested.getMethod("setVal", Int::class.javaPrimitiveType)
                setVal.invoke(wrapper, value)
                val setter = cfg.javaClass.getMethod(setterName, nested)
                setter.invoke(cfg, wrapper)
            } catch (e: Throwable) {
                Log.w(TAG, "setOxyIIConfig: skipping '$setterName' — ${e.message}")
            }
        }
        (fields["spo2RemindSw"] as? Int)?.let { assignNested("setSpo2Switch", "Spo2Switch", it) }
        (fields["spo2Thr"]     as? Int)?.let { assignNested("setSpo2Low",    "Spo2Low",    it) }
        (fields["hrRemindSw"]  as? Int)?.let { assignNested("setHrSwitch",   "HrSwitch",   it) }
        (fields["hrThrLow"]    as? Int)?.let { assignNested("setHrLow",      "HrLow",      it) }
        (fields["hrThrHigh"]   as? Int)?.let { assignNested("setHrHi",       "HrHigh",     it) }
        (fields["motor"]       as? Int)?.let { assignNested("setMotor",      "Motor",      it) }
        (fields["buzzer"]      as? Int)?.let { assignNested("setBuzzer",     "Buzzer",     it) }
        (fields["displayMode"] as? Int)?.let { assignNested("setDisplayMode","DisplayMode",it) }
        (fields["brightness"]  as? Int)?.let { assignNested("setBrightnessMode","BrightnessMode",it) }
        (fields["interval"]    as? Int)?.let { assignNested("setStorageInterval","StorageInterval", it) }
        BleServiceHelper.BleServiceHelper.oxyIISetConfig(model, cfg)
        result.success(true)
    }

    // ════════════════════════════════════════════════════════════════════
    // Real-time measurement
    // ════════════════════════════════════════════════════════════════════

    private fun handleStartMeasurement(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) {
            result.error("NOT_CONNECTED", "No device connected", null)
            return
        }
        try {
            // AirBP / SmartBP doesn't use the generic startRtTask hook;
            // the Lepu SDK exposes a dedicated `airBpStartBpTest` that
            // posts EventAirBpRtData / EventAirBpRtState / EventAirBpRtResult
            // back through LiveEventBus. Same wire format as iOS's
            // VTAirBPCmdStartMeasure handler.
            if (model == Bluetooth.MODEL_AIRBP) {
                BleServiceHelper.BleServiceHelper.airBpStartBpTest(model)
            } else {
                BleServiceHelper.BleServiceHelper.startRtTask(model)
                // BP2A exposes a remote-start command (0x40) that tells the
                // device to begin inflating immediately — the same command
                // the iOS VTM SDK sends internally when startMeasurement is
                // called. Without it the cuff only inflates when the user
                // presses the physical button on the device.
                // BP2 / BP2T / BP2W do NOT have a remote-start opcode;
                // those models always require the physical button.
                if (model == Bluetooth.MODEL_BP2A) {
                    bp2aAutoStartPending = true
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("START_RT_FAILED", e.message, null)
        }
    }

    private fun handleStopMeasurement(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) {
            result.error("NOT_CONNECTED", "No device connected", null)
            return
        }
        bp2aAutoStartPending = false
        try {
            // For BP2A, send the remote-stop command so the device
            // releases cuff pressure even if the user exits the page
            // before the measurement completes. stopRtTask then tears
            // down the event-bus subscription.
            if (model == Bluetooth.MODEL_BP2A) {
                BleServiceHelper.BleServiceHelper.bp2aCmd0x40(model, false, false)
            }
            BleServiceHelper.BleServiceHelper.stopRtTask(model)
            result.success(true)
        } catch (e: Exception) {
            result.error("STOP_RT_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Device info / file list / factory reset
    // ════════════════════════════════════════════════════════════════════

    private fun handleGetDeviceInfo(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (model) {
                Bluetooth.MODEL_ER1, Bluetooth.MODEL_ER1_N, Bluetooth.MODEL_HHM1,
                Bluetooth.MODEL_ER1S, Bluetooth.MODEL_ER1_S, Bluetooth.MODEL_ER1_H,
                Bluetooth.MODEL_ER1_W, Bluetooth.MODEL_ER1_L ->
                    BleServiceHelper.BleServiceHelper.er1GetInfo(model)
                Bluetooth.MODEL_ER2, Bluetooth.MODEL_LP_ER2, Bluetooth.MODEL_DUOEK,
                Bluetooth.MODEL_LEPU_ER2, Bluetooth.MODEL_HHM2, Bluetooth.MODEL_HHM3,
                Bluetooth.MODEL_ER2_S ->
                    BleServiceHelper.BleServiceHelper.er2GetInfo(model)
                Bluetooth.MODEL_O2RING, Bluetooth.MODEL_O2M, Bluetooth.MODEL_BABYO2,
                Bluetooth.MODEL_BABYO2N, Bluetooth.MODEL_CHECKO2, Bluetooth.MODEL_SLEEPO2,
                Bluetooth.MODEL_SNOREO2, Bluetooth.MODEL_WEARO2, Bluetooth.MODEL_SLEEPU,
                Bluetooth.MODEL_OXYLINK, Bluetooth.MODEL_KIDSO2, Bluetooth.MODEL_OXYFIT,
                Bluetooth.MODEL_OXYRING, Bluetooth.MODEL_BBSM_S1, Bluetooth.MODEL_BBSM_S2,
                Bluetooth.MODEL_OXYU, Bluetooth.MODEL_AI_S100, Bluetooth.MODEL_O2M_WPS,
                Bluetooth.MODEL_CMRING, Bluetooth.MODEL_OXYFIT_WPS, Bluetooth.MODEL_KIDSO2_WPS,
                Bluetooth.MODEL_BBSM_S3, Bluetooth.MODEL_O2RING_RE, Bluetooth.MODEL_O2RINGF ->
                    BleServiceHelper.BleServiceHelper.oxyGetInfo(model)
                Bluetooth.MODEL_BP2, Bluetooth.MODEL_BP2A, Bluetooth.MODEL_BP2T ->
                    BleServiceHelper.BleServiceHelper.bp2GetInfo(model)
                Bluetooth.MODEL_PF_10AW_1, Bluetooth.MODEL_PF_10BWS,
                Bluetooth.MODEL_SA10AW_PU, Bluetooth.MODEL_PF10BW_VE ->
                    BleServiceHelper.BleServiceHelper.pf10Aw1GetInfo(model)
                Bluetooth.MODEL_AIRBP ->
                    BleServiceHelper.BleServiceHelper.airBpGetInfo(model)
                else -> {}
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("GET_INFO_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // File transfer (history download)
    //
    // Each Lepu device family stores measurement records on its on-board
    // flash. The on-device protocol exposes:
    //
    //   1.  GET_FILE_LIST → returns ArrayList<String> of file names.
    //   2.  READ_FILE     → starts a chunked download of one file.
    //   3.  Per-chunk progress reports (0..100 percent).
    //   4.  COMPLETE      → parsed file struct (Bp2File / Er1File / OxyFile…)
    //   5.  ERROR         → failure reason.
    //
    // The helper below classifies a `model` int into a "file-transfer family"
    // string. Each handler dispatches to the correct BleServiceHelper.xxxYyy
    // method; the LiveEventBus subscriptions further down forward the events
    // back to Dart with a stable wire-format.
    // ════════════════════════════════════════════════════════════════════

    private enum class FileFamily { ER1, ER2, BP2, OXY, OXYII, PF10AW1, NONE }

    private fun fileFamilyForModel(model: Int): FileFamily = when (model) {
        Bluetooth.MODEL_ER1, Bluetooth.MODEL_ER1_N, Bluetooth.MODEL_HHM1,
        Bluetooth.MODEL_ER1S, Bluetooth.MODEL_ER1_S, Bluetooth.MODEL_ER1_H,
        Bluetooth.MODEL_ER1_W, Bluetooth.MODEL_ER1_L -> FileFamily.ER1

        Bluetooth.MODEL_ER2, Bluetooth.MODEL_LP_ER2, Bluetooth.MODEL_DUOEK,
        Bluetooth.MODEL_LEPU_ER2, Bluetooth.MODEL_HHM2, Bluetooth.MODEL_HHM3,
        Bluetooth.MODEL_ER2_S -> FileFamily.ER2

        Bluetooth.MODEL_BP2, Bluetooth.MODEL_BP2A, Bluetooth.MODEL_BP2T ->
            FileFamily.BP2

        // Legacy O2Ring / O2M family — file list is bundled into oxyGetInfo's
        // DeviceInfo response (see EventOxyInfo handler below). Reading uses
        // oxyReadFile / EventOxyReadingFileProgress / EventOxyReadFileComplete.
        Bluetooth.MODEL_O2RING, Bluetooth.MODEL_O2M, Bluetooth.MODEL_BABYO2,
        Bluetooth.MODEL_BABYO2N, Bluetooth.MODEL_CHECKO2, Bluetooth.MODEL_SLEEPO2,
        Bluetooth.MODEL_SNOREO2, Bluetooth.MODEL_WEARO2, Bluetooth.MODEL_SLEEPU,
        Bluetooth.MODEL_OXYLINK, Bluetooth.MODEL_KIDSO2, Bluetooth.MODEL_OXYFIT,
        Bluetooth.MODEL_OXYRING, Bluetooth.MODEL_BBSM_S1, Bluetooth.MODEL_BBSM_S2,
        Bluetooth.MODEL_OXYU, Bluetooth.MODEL_AI_S100 -> FileFamily.OXY

        // OxyII protocol — the "WPS" / refreshed O2Ring family.
        Bluetooth.MODEL_O2M_WPS, Bluetooth.MODEL_OXYFIT_WPS,
        Bluetooth.MODEL_KIDSO2_WPS, Bluetooth.MODEL_BBSM_S3,
        Bluetooth.MODEL_O2RING_RE, Bluetooth.MODEL_O2RINGF,
        Bluetooth.MODEL_CMRING -> FileFamily.OXYII

        Bluetooth.MODEL_PF_10AW_1, Bluetooth.MODEL_PF_10BWS,
        Bluetooth.MODEL_SA10AW_PU, Bluetooth.MODEL_PF10BW_VE ->
            FileFamily.PF10AW1

        else -> FileFamily.NONE
    }

    private fun fileFamilyName(f: FileFamily): String = when (f) {
        FileFamily.ER1     -> "er1"
        FileFamily.ER2     -> "er2"
        FileFamily.BP2     -> "bp2"
        FileFamily.OXY     -> "oxy"
        FileFamily.OXYII   -> "oxyII"
        FileFamily.PF10AW1 -> "pf10aw1"
        FileFamily.NONE    -> "unknown"
    }

    // ── Catch-up on mid-recording (re)connect ───────────────────────────
    //
    // When the phone joins a device that's already in the middle of a
    // recording, the live `rtData` stream can only deliver samples from
    // the moment we subscribe. The *full* recording — including samples
    // from before our connection — is persisted to the device's flash as
    // a file once the device's curStatus transitions into the "saved"
    // terminal state. This plugin detects that transition, asks for a
    // fresh file list, diffs it against the files we already knew about,
    // and auto-pulls the new entry. Consumers get:
    //
    //   • `recordingFinished` — informational, fires on the transition.
    //   • `fileList` — refreshed list.
    //   • `fileReadProgress` / `fileReadComplete` — for the auto-pull.
    //
    // The `autoFetchOnFinish` flag (defaulting to `true`) is forwarded
    // from the Dart `connect()` call. Consumers who want full manual
    // control can pass `autoFetchOnFinish: false` and orchestrate the
    // sequence themselves.
    private fun emitRecordingFinished(family: String, model: Int) {
        sendEvent(mapOf(
            "event"        to "recordingFinished",
            "deviceFamily" to family,
            "model"        to model,
        ))
    }

    private fun triggerGetFileList(family: FileFamily, model: Int) {
        try {
            when (family) {
                FileFamily.ER1 ->
                    BleServiceHelper.BleServiceHelper.er1GetFileList(model)
                FileFamily.ER2 ->
                    BleServiceHelper.BleServiceHelper.er2GetFileList(model)
                FileFamily.BP2 ->
                    BleServiceHelper.BleServiceHelper.bp2GetFileList(model)
                FileFamily.OXYII ->
                    BleServiceHelper.BleServiceHelper.oxyIIGetFileList(
                        model,
                        com.lepu.blepro.constants.Constant.OxyIIFileType.OXY,
                    )
                FileFamily.PF10AW1 ->
                    BleServiceHelper.BleServiceHelper.pf10Aw1GetFileList(model)
                FileFamily.OXY ->
                    BleServiceHelper.BleServiceHelper.oxyGetInfo(model)
                FileFamily.NONE -> { /* nothing to do */ }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "triggerGetFileList($family, $model) failed: ${e.message}")
        }
    }

    private fun triggerReadFile(family: FileFamily, model: Int, fileName: String) {
        // Cache for ER1's `continueReadFile(model, fileName)` lookup.
        lastReadFileNameByModel[model] = fileName
        try {
            when (family) {
                FileFamily.ER1 ->
                    BleServiceHelper.BleServiceHelper.er1ReadFile(model, fileName)
                FileFamily.ER2 ->
                    BleServiceHelper.BleServiceHelper.er2ReadFile(model, fileName)
                FileFamily.BP2 ->
                    BleServiceHelper.BleServiceHelper.bp2ReadFile(model, fileName)
                FileFamily.OXY ->
                    BleServiceHelper.BleServiceHelper.oxyReadFile(model, fileName)
                FileFamily.OXYII ->
                    BleServiceHelper.BleServiceHelper.oxyIIReadFile(
                        model,
                        fileName,
                        com.lepu.blepro.constants.Constant.OxyIIFileType.OXY,
                    )
                FileFamily.PF10AW1 ->
                    BleServiceHelper.BleServiceHelper.pf10Aw1ReadFile(model, fileName)
                FileFamily.NONE -> { /* nothing to do */ }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "triggerReadFile($family, $model, $fileName) failed: ${e.message}")
        }
    }

    /// Called after every `fileList` event. Captures the current set of
    /// files as a baseline on the first invocation for this model, and on
    /// subsequent invocations diffs the incoming list against that
    /// baseline to identify freshly-recorded files. If
    /// `autoFetchOnFinish` is on, each new file is downloaded in sequence
    /// (the SDK serialises them internally).
    ///
    /// Special case: if `pendingCatchUpByModel` contains this model, the
    /// caller was `onRecordingFinishedTransition`, so at least one new
    /// file exists *by definition*. In that case we bypass the
    /// "first-list-is-baseline" short-circuit and pull the diff — or
    /// the tail of the list if the session has no baseline to diff
    /// against, since Lepu returns file names as `yyyyMMddHHmmss` in
    /// ascending chronological order and the newest entry is always
    /// the just-saved recording.
    private fun maybeTriggerCatchUp(
        family: FileFamily,
        model: Int,
        files: List<String>,
    ) {
        if (family == FileFamily.NONE) return
        val known = knownFilesByModel.getOrPut(model) { mutableSetOf() }
        val isFirstList = known.isEmpty()
        val hasPendingCatchUp = pendingCatchUpByModel.remove(model)
        val toFetch = chooseCatchUpTargets(
            files = files,
            known = known,
            autoFetchOnFinish = autoFetchOnFinish,
            hasPendingCatchUp = hasPendingCatchUp,
        )
        known.addAll(files)
        if (toFetch.isEmpty()) return

        Log.i(
            TAG,
            "Auto-fetching ${toFetch.size} file(s) for model=$model " +
                "family=${fileFamilyName(family)}: $toFetch " +
                "(pendingCatchUp=$hasPendingCatchUp, isFirstList=$isFirstList)",
        )
        // The Lepu SDK does not safely support overlapping readFile
        // calls on most families, so trigger each one sequentially and
        // rely on EventXxxReadFileComplete to pipeline them. For
        // simplicity (and because 99% of the time the diff is a single
        // entry), we post them all and let the SDK queue internally.
        for (name in toFetch) {
            mainHandler.post { triggerReadFile(family, model, name) }
        }
    }

    /// Called from rtData observers when we detect the recording-saved
    /// transition (ER1/ER2 `curStatus == 4`, BP2 `measureType == ecg_result` /
    /// `bp_result`). Emits the `recordingFinished` event and kicks off a
    /// fresh file-list pull, whose callback will in turn invoke
    /// `maybeTriggerCatchUp`. We flag the model in
    /// `pendingCatchUpByModel` first so that `maybeTriggerCatchUp`
    /// knows this enumeration is guaranteed to contain a new file
    /// (even if it's also the session's very first enumeration).
    private fun onRecordingFinishedTransition(family: FileFamily, model: Int) {
        if (family == FileFamily.NONE) return
        emitRecordingFinished(fileFamilyName(family), model)
        if (autoFetchOnFinish) {
            pendingCatchUpByModel.add(model)
            mainHandler.post { triggerGetFileList(family, model) }
        }
    }

    private fun handleGetFileList(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (fileFamilyForModel(model)) {
                FileFamily.ER1 ->
                    BleServiceHelper.BleServiceHelper.er1GetFileList(model)
                FileFamily.ER2 ->
                    BleServiceHelper.BleServiceHelper.er2GetFileList(model)
                FileFamily.BP2 ->
                    BleServiceHelper.BleServiceHelper.bp2GetFileList(model)
                FileFamily.OXYII ->
                    BleServiceHelper.BleServiceHelper.oxyIIGetFileList(
                        model,
                        com.lepu.blepro.constants.Constant.OxyIIFileType.OXY,
                    )
                FileFamily.PF10AW1 ->
                    BleServiceHelper.BleServiceHelper.pf10Aw1GetFileList(model)
                FileFamily.OXY -> {
                    // Legacy O2Ring path: the Lepu SDK does not expose a
                    // dedicated file-list command. The file list piggy-backs
                    // on the device-info response, so we re-trigger that and
                    // emit a `fileList` event from the EventOxyInfo handler.
                    BleServiceHelper.BleServiceHelper.oxyGetInfo(model)
                }
                FileFamily.NONE -> {
                    result.error("UNSUPPORTED",
                        "Model $model does not expose a file list API",
                        null)
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("GET_FILE_LIST_FAILED", e.message, null)
        }
    }

    private fun handleReadFile(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        val fileName = call.argument<String>("fileName")
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        if (fileName.isNullOrEmpty()) {
            result.error("BAD_ARG", "fileName is required", null); return
        }
        // Cache for ER1's `continueReadFile(model, fileName)` lookup.
        lastReadFileNameByModel[model] = fileName
        try {
            when (fileFamilyForModel(model)) {
                FileFamily.ER1 ->
                    BleServiceHelper.BleServiceHelper.er1ReadFile(model, fileName)
                FileFamily.ER2 ->
                    BleServiceHelper.BleServiceHelper.er2ReadFile(model, fileName)
                FileFamily.BP2 ->
                    BleServiceHelper.BleServiceHelper.bp2ReadFile(model, fileName)
                FileFamily.OXY ->
                    BleServiceHelper.BleServiceHelper.oxyReadFile(model, fileName)
                FileFamily.OXYII ->
                    BleServiceHelper.BleServiceHelper.oxyIIReadFile(
                        model,
                        fileName,
                        com.lepu.blepro.constants.Constant.OxyIIFileType.OXY,
                    )
                FileFamily.PF10AW1 ->
                    BleServiceHelper.BleServiceHelper.pf10Aw1ReadFile(model, fileName)
                FileFamily.NONE -> {
                    result.error("UNSUPPORTED",
                        "Model $model does not support file download",
                        null)
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("READ_FILE_FAILED", e.message, null)
        }
    }

    private fun handleCancelReadFile(call: MethodCall, result: Result) {
        // Only the ER1 family exposes a cancel-mid-download command in the
        // Lepu SDK; for other families the only way to abort is to disconnect.
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (fileFamilyForModel(model)) {
                FileFamily.ER1 ->
                    BleServiceHelper.BleServiceHelper.er1CancelReadFile(model)
                else -> {
                    result.error("UNSUPPORTED",
                        "cancelReadFile is only available on ER1-family devices",
                        null)
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("CANCEL_READ_FAILED", e.message, null)
        }
    }

    private fun handlePauseReadFile(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (fileFamilyForModel(model)) {
                FileFamily.ER1 ->
                    BleServiceHelper.BleServiceHelper.er1PauseReadFile(model)
                else -> {
                    result.error("UNSUPPORTED",
                        "pauseReadFile is only available on ER1-family devices",
                        null)
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("PAUSE_READ_FAILED", e.message, null)
        }
    }

    private fun handleContinueReadFile(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (fileFamilyForModel(model)) {
                FileFamily.ER1 -> {
                    // The 1.2.0 AAR removed the single-arg er1ContinueReadFile
                    // overload from the public API; the canonical signature
                    // is now (model, fileName). Look up the in-flight name.
                    val fileName = call.argument<String>("fileName")
                        ?: lastReadFileNameByModel[model]
                    if (fileName.isNullOrEmpty()) {
                        result.error(
                            "BAD_STATE",
                            "continueReadFile called without an in-flight readFile() " +
                                "and no explicit fileName argument",
                            null,
                        )
                        return
                    }
                    BleServiceHelper.BleServiceHelper.er1ContinueReadFile(model, fileName)
                }
                else -> {
                    result.error("UNSUPPORTED",
                        "continueReadFile is only available on ER1-family devices",
                        null)
                    return
                }
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("CONTINUE_READ_FAILED", e.message, null)
        }
    }

    // Politely power off the device. The Lepu SDK does NOT expose a
    // dedicated shutdown opcode for any family — every method in
    // `BleServiceHelper` is for read/write/measurement only, and there
    // is no `xxxShutdown`/`xxxPowerOff`. The closest match is BP2's
    // `bp2SwitchState(model, 4)` (state 4 = shutdown in the BP2
    // firmware enum), but the public Kotlin API doesn't expose it.
    //
    // Until upstream surfaces a shutdown API we return UNSUPPORTED so
    // consumers can fall back to `disconnect()`. On iOS the BP2 path
    // works via VTMBPTargetStatusEnd; this asymmetry is documented in
    // the README.
    private fun handleShutdown(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        result.error(
            "UNSUPPORTED",
            "shutdown is not exposed by lepu-blepro for any family on Android; disconnect instead.",
            mapOf("model" to model),
        )
    }

    private fun handleFactoryReset(call: MethodCall, result: Result) {
        val model = call.argument<Int>("model") ?: connectedModel
        if (model < 0) { result.error("NOT_CONNECTED", "No device connected", null); return }
        try {
            when (model) {
                Bluetooth.MODEL_ER1, Bluetooth.MODEL_ER1_N, Bluetooth.MODEL_HHM1,
                Bluetooth.MODEL_ER1S, Bluetooth.MODEL_ER1_S, Bluetooth.MODEL_ER1_H,
                Bluetooth.MODEL_ER1_W, Bluetooth.MODEL_ER1_L ->
                    BleServiceHelper.BleServiceHelper.er1FactoryReset(model)
                Bluetooth.MODEL_ER2, Bluetooth.MODEL_LP_ER2, Bluetooth.MODEL_DUOEK,
                Bluetooth.MODEL_LEPU_ER2, Bluetooth.MODEL_HHM2, Bluetooth.MODEL_HHM3,
                Bluetooth.MODEL_ER2_S ->
                    BleServiceHelper.BleServiceHelper.er2FactoryReset(model)
                Bluetooth.MODEL_O2RING, Bluetooth.MODEL_O2M, Bluetooth.MODEL_BABYO2,
                Bluetooth.MODEL_BABYO2N, Bluetooth.MODEL_CHECKO2, Bluetooth.MODEL_SLEEPO2,
                Bluetooth.MODEL_SNOREO2, Bluetooth.MODEL_WEARO2, Bluetooth.MODEL_SLEEPU,
                Bluetooth.MODEL_OXYLINK, Bluetooth.MODEL_KIDSO2, Bluetooth.MODEL_OXYFIT,
                Bluetooth.MODEL_OXYRING, Bluetooth.MODEL_BBSM_S1, Bluetooth.MODEL_BBSM_S2,
                Bluetooth.MODEL_OXYU, Bluetooth.MODEL_AI_S100 ->
                    BleServiceHelper.BleServiceHelper.oxyFactoryReset(model)
                Bluetooth.MODEL_BP2, Bluetooth.MODEL_BP2A, Bluetooth.MODEL_BP2T ->
                    BleServiceHelper.BleServiceHelper.bp2FactoryReset(model)
                Bluetooth.MODEL_PF_10AW_1, Bluetooth.MODEL_PF_10BWS,
                Bluetooth.MODEL_SA10AW_PU, Bluetooth.MODEL_PF10BW_VE ->
                    BleServiceHelper.BleServiceHelper.pf10Aw1FactoryReset(model)
                Bluetooth.MODEL_AIRBP ->
                    BleServiceHelper.BleServiceHelper.airBpFactoryReset(model)
                else -> {}
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("FACTORY_RESET_FAILED", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // LiveEventBus → EventChannel bridge
    // ════════════════════════════════════════════════════════════════════

    private fun sendEvent(map: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(map) }
    }

    private fun registerLiveEventBus() {
        // ── Service ready ───────────────────────────────────────────
        LiveEventBus.get<Boolean>(EventMsgConst.Ble.EventServiceConnectedAndInterfaceInit)
            .observeForever { _ ->
                sendEvent(mapOf("event" to "serviceReady"))
            }

        // ── Device discovered ───────────────────────────────────────
        LiveEventBus.get<Bluetooth>(EventMsgConst.Discovery.EventDeviceFound)
            .observeForever { _ ->
                val devices = BluetoothController.getDevices()
                for (d in devices) {
                    sendEvent(mapOf(
                        "event" to "deviceFound",
                        "name" to (d.name ?: ""),
                        "mac" to (d.macAddr ?: ""),
                        "model" to d.model,
                        "rssi" to d.rssi,
                        "sdk" to "lepu"
                    ))
                }
            }

        // ── Device ready (connection complete) ──────────────────────
        LiveEventBus.get<Int>(EventMsgConst.Ble.EventBleDeviceReady)
            .observeForever { model ->
                connectedModel = model
                sendEvent(mapOf(
                    "event" to "connectionState",
                    "state" to "connected",
                    "model" to model,
                ))
            }

        // ── Device disconnect reason ────────────────────────────────
        LiveEventBus.get<Int>(EventMsgConst.Ble.EventBleDeviceDisconnectReason)
            .observeForever { reason ->
                val reasonStr = when (reason) {
                    ConnectionObserver.REASON_SUCCESS -> "user_initiated"
                    ConnectionObserver.REASON_TERMINATE_LOCAL_HOST -> "local_disconnect"
                    ConnectionObserver.REASON_TERMINATE_PEER_USER -> "remote_disconnect"
                    ConnectionObserver.REASON_LINK_LOSS -> "link_loss"
                    ConnectionObserver.REASON_NOT_SUPPORTED -> "not_supported"
                    ConnectionObserver.REASON_TIMEOUT -> "timeout"
                    else -> "unknown"
                }
                connectedModel = -1
                sendEvent(mapOf(
                    "event" to "connectionState",
                    "state" to "disconnected",
                    "reason" to reasonStr,
                ))
            }

        // ════════════════════════════════════════════════════════════
        // ER1 real-time data
        // ════════════════════════════════════════════════════════════
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1RtData)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.er1.RtData
                    val status = data.param.curStatus
                    sendEvent(mapOf(
                        "event" to "rtData",
                        "deviceType" to "ecg",
                        "deviceFamily" to "er1",
                        "model" to event.model,
                        "hr" to data.param.hr,
                        "battery" to data.param.battery,
                        "batteryState" to data.param.batteryState,
                        "recordTime" to data.param.recordTime,
                        "curStatus" to status,
                        "ecgFloats" to data.wave.ecgFloats?.toList(),
                        "ecgShorts" to data.wave.ecgShorts?.toList(),
                        "samplingRate" to 125,
                        "mvConversion" to 0.002467,
                    ))
                    // Detect the idle/measuring → "saving succeed" transition
                    // so we can auto-pull the freshly-saved file (which
                    // contains *all* samples, including any captured before
                    // the consumer connected).
                    if (status == 4 && lastEr1CurStatus != 4) {
                        onRecordingFinishedTransition(FileFamily.ER1, event.model)
                    }
                    lastEr1CurStatus = status
                } catch (e: Exception) {
                    Log.e(TAG, "ER1 RT error", e)
                }
            }

        // ════════════════════════════════════════════════════════════
        // ER2 real-time data
        // ════════════════════════════════════════════════════════════
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2RtData)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.er2.RtData
                    val status = data.param.curStatus
                    sendEvent(mapOf(
                        "event" to "rtData",
                        "deviceType" to "ecg",
                        "deviceFamily" to "er2",
                        "model" to event.model,
                        "hr" to data.param.hr,
                        "battery" to data.param.battery,
                        "batteryState" to data.param.batteryState,
                        "recordTime" to data.param.recordTime,
                        "curStatus" to status,
                        "ecgFloats" to data.wave.ecgFloats?.toList(),
                        "ecgShorts" to data.wave.ecgShorts?.toList(),
                        "samplingRate" to 125,
                        "mvConversion" to 0.002467,
                    ))
                    if (status == 4 && lastEr2CurStatus != 4) {
                        onRecordingFinishedTransition(FileFamily.ER2, event.model)
                    }
                    lastEr2CurStatus = status
                } catch (e: Exception) {
                    Log.e(TAG, "ER2 RT error", e)
                }
            }

        // ER2 connection events
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2SetTime)
            .observeForever { event ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to event.model, "subEvent" to "setTime",
                ))
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2Info)
            .observeForever { event ->
                try {
                    sendEvent(mapOf("event" to "deviceInfo", "model" to event.model, "data" to event.data.toString()))
                } catch (e: Exception) { Log.e(TAG, "ER2 Info error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2FileList)
            .observeForever { event ->
                try {
                    val files = extractFileList(event.data)
                    sendEvent(mapOf("event" to "fileList", "model" to event.model,
                        "deviceFamily" to "er2", "files" to files))
                    maybeTriggerCatchUp(FileFamily.ER2, event.model, files)
                } catch (e: Exception) { Log.e(TAG, "ER2 FileList error", e) }
            }

        // ER1 connection events
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1SetTime)
            .observeForever { event ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to event.model, "subEvent" to "setTime",
                ))
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1Info)
            .observeForever { event ->
                try {
                    sendEvent(mapOf("event" to "deviceInfo", "model" to event.model, "data" to event.data.toString()))
                } catch (e: Exception) { Log.e(TAG, "ER1 Info error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1FileList)
            .observeForever { event ->
                try {
                    val files = extractFileList(event.data)
                    sendEvent(mapOf("event" to "fileList", "model" to event.model,
                        "deviceFamily" to "er1", "files" to files))
                    maybeTriggerCatchUp(FileFamily.ER1, event.model, files)
                } catch (e: Exception) { Log.e(TAG, "ER1 FileList error", e) }
            }

        // ════════════════════════════════════════════════════════════
        // Oximeter (O2Ring family)
        // ════════════════════════════════════════════════════════════
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyRtParamData)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.oxy.RtParam
                    sendEvent(mapOf(
                        "event" to "rtData",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "oxy",
                        "model" to event.model,
                        "spo2" to data.spo2,
                        "pr" to data.pr,
                        "pi" to data.pi,
                        "battery" to data.battery,
                        "batteryState" to data.batteryState,
                        "state" to data.state,
                    ))
                } catch (e: Exception) { Log.e(TAG, "Oxy RT error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyRtData)
            .observeForever { event ->
                try {
                    sendEvent(mapOf(
                        "event" to "rtWaveform",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "oxy",
                        "model" to event.model,
                        "waveData" to event.data.toString(),
                    ))
                } catch (e: Exception) { Log.e(TAG, "Oxy Wave error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxySyncDeviceInfo)
            .observeForever { event ->
                try {
                    // EventOxySyncDeviceInfo posts an Array<String>. Filter
                    // through Any[] then keep only String elements to side-
                    // step the UNCHECKED_CAST that Array<String> would
                    // otherwise trigger via Java's erased generics.
                    val arr = event.data as? Array<*> ?: return@observeForever
                    val types = arr.filterIsInstance<String>()
                    if (types.isNotEmpty() && types[0] == "SetTIME") {
                        sendEvent(mapOf(
                            "event" to "connectionState", "state" to "connected",
                            "model" to event.model, "subEvent" to "setTime",
                        ))
                    }
                } catch (e: Exception) { Log.e(TAG, "Oxy Sync error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyInfo)
            .observeForever { event ->
                try {
                    sendEvent(mapOf("event" to "deviceInfo", "model" to event.model, "data" to event.data.toString()))
                    // Legacy O2Ring exposes the file list as part of DeviceInfo,
                    // so unwrap it and emit a `fileList` event too. We use
                    // reflection because the DeviceInfo class lives in a sealed
                    // package; this stays robust if the field is absent.
                    val info = event.data
                    val fileList = try {
                        val getter = info.javaClass.getMethod("getFileList")
                        getter.invoke(info)
                    } catch (_: Throwable) { null }
                    if (fileList is List<*>) {
                        val files = fileList.filterIsInstance<String>()
                        if (files.isNotEmpty()) {
                            sendEvent(mapOf(
                                "event" to "fileList",
                                "model" to event.model,
                                "deviceFamily" to "oxy",
                                "files" to files,
                            ))
                            maybeTriggerCatchUp(FileFamily.OXY, event.model, files)
                        }
                    }
                } catch (e: Exception) { Log.e(TAG, "Oxy Info error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyPpgData)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.oxy.RtPpg
                    sendEvent(mapOf(
                        "event" to "rtWaveform",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "oxy",
                        "model" to event.model,
                        "waveType" to "ppg",
                        "irSize" to data.ir.size,
                        "ir" to data.ir.toList(),
                        "red" to data.red.toList(),
                    ))
                } catch (e: Exception) { Log.e(TAG, "Oxy PPG error", e) }
            }

        // ════════════════════════════════════════════════════════════
        // PC60FW / PF10 family
        // ════════════════════════════════════════════════════════════
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.PC60Fw.EventPC60FwRtParam)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.pc60fw.RtParam
                    sendEvent(mapOf(
                        "event" to "rtData",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "pc60fw",
                        "model" to event.model,
                        "spo2" to data.spo2,
                        "pr" to data.pr,
                        "pi" to data.pi,
                    ))
                } catch (e: Exception) { Log.e(TAG, "PC60FW RT error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.PC60Fw.EventPC60FwRtWave)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.pc60fw.RtWave
                    sendEvent(mapOf(
                        "event" to "rtWaveform",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "pc60fw",
                        "model" to event.model,
                        "waveData" to data.waveIntData?.toList(),
                    ))
                } catch (e: Exception) { Log.e(TAG, "PC60FW Wave error", e) }
            }

        // ════════════════════════════════════════════════════════════
        // PF10AW1/PF10BWS family
        // ════════════════════════════════════════════════════════════
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1RtParam)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.pf10aw1.RtParam
                    sendEvent(mapOf(
                        "event" to "rtData",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "pf10aw1",
                        "model" to event.model,
                        "spo2" to data.spo2,
                        "pr" to data.pr,
                        "pi" to data.pi,
                        "batLevel" to data.batLevel,
                    ))
                } catch (e: Exception) { Log.e(TAG, "PF10AW1 RT error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1RtWave)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.pf10aw1.RtWave
                    sendEvent(mapOf(
                        "event" to "rtWaveform",
                        "deviceType" to "oximeter",
                        "deviceFamily" to "pf10aw1",
                        "model" to event.model,
                        "waveData" to data.waveIntData?.toList(),
                    ))
                } catch (e: Exception) { Log.e(TAG, "PF10AW1 Wave error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1SetTime)
            .observeForever { event ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to event.model, "subEvent" to "setTime",
                ))
            }

        // ════════════════════════════════════════════════════════════
        // BP2 real-time data
        // ════════════════════════════════════════════════════════════
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2SyncTime)
            .observeForever { event ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to event.model, "subEvent" to "setTime",
                ))
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2RtData)
            .observeForever { event ->
                try {
                    val data = event.data as com.lepu.blepro.ext.bp2.RtData
                    val baseMap = mutableMapOf<String, Any?>(
                        "event" to "rtData",
                        "deviceType" to "bp",
                        "deviceFamily" to "bp2",
                        "model" to event.model,
                        "deviceStatus" to data.status.deviceStatus,
                        "batteryStatus" to data.status.batteryStatus,
                        "batteryPercent" to data.status.percent,
                        "paramDataType" to data.param.paramDataType,
                    )
                    val devStatus = data.status.deviceStatus
                    // Auto-start: fire the start command the first time the
                    // device reports STATUS_READY (3) after startMeasurement.
                    // Sending it synchronously at connection time races the
                    // device's post-connect init and is silently ignored.
                    if (bp2aAutoStartPending) {
                        when (devStatus) {
                            3 -> { // STATUS_READY
                                bp2aAutoStartPending = false
                                BleServiceHelper.BleServiceHelper.bp2aCmd0x40(event.model, true, false)
                            }
                            4, 5 -> bp2aAutoStartPending = false // already measuring / just ended
                        }
                    }
                    when (data.param.paramDataType) {
                        0 -> {
                            val bpIng = com.lepu.blepro.ext.bp2.RtBpIng(data.param.paramData)
                            baseMap["measureType"] = "bp_measuring"
                            baseMap["pressure"] = bpIng.pressure
                            baseMap["pr"] = bpIng.pr
                            baseMap["isDeflate"] = bpIng.isDeflate
                            baseMap["isPulse"] = bpIng.isPulse
                        }
                        1 -> {
                            val bpResult = com.lepu.blepro.ext.bp2.RtBpResult(data.param.paramData)
                            baseMap["measureType"] = "bp_result"
                            baseMap["sys"] = bpResult.sys
                            baseMap["dia"] = bpResult.dia
                            baseMap["mean"] = bpResult.mean
                            baseMap["pr"] = bpResult.pr
                            baseMap["result"] = bpResult.result
                        }
                        2 -> {
                            val ecgIng = com.lepu.blepro.ext.bp2.RtEcgIng(data.param.paramData)
                            baseMap["measureType"] = "ecg_measuring"
                            baseMap["hr"] = ecgIng.hr
                            baseMap["isLeadOff"] = ecgIng.isLeadOff
                            baseMap["isPoolSignal"] = ecgIng.isPoolSignal
                            baseMap["curDuration"] = ecgIng.curDuration
                            baseMap["ecgFloats"] = data.param.ecgFloats?.toList()
                            baseMap["ecgShorts"] = data.param.ecgShorts?.toList()
                            baseMap["samplingRate"] = 250
                            baseMap["mvConversion"] = 0.003098
                        }
                        3 -> {
                            val ecgResult = com.lepu.blepro.ext.bp2.RtEcgResult(data.param.paramData)
                            baseMap["measureType"] = "ecg_result"
                            baseMap["hr"] = ecgResult.hr
                            baseMap["qrs"] = ecgResult.qrs
                            baseMap["pvcs"] = ecgResult.pvcs
                            baseMap["qtc"] = ecgResult.qtc
                            baseMap["resultMessage"] = ecgResult.diagnosis.resultMess
                        }
                    }
                    sendEvent(baseMap)

                    // BP2 recording-finished transition: the device
                    // writes a new file to flash as soon as we see
                    // measureType `ecg_result` (ECG recording saved) or
                    // `bp_result` (cuff measurement saved).  We treat the
                    // first such event after any non-result measureType
                    // as the edge trigger, so repeated `*_result` frames
                    // don't re-pull the same file.
                    val mt = (baseMap["measureType"] as? String) ?: ""
                    val isResult = mt == "ecg_result" || mt == "bp_result"
                    if (isResult && lastBp2MeasureType != mt) {
                        onRecordingFinishedTransition(FileFamily.BP2, event.model)
                    }
                    lastBp2MeasureType = mt
                } catch (e: Exception) { Log.e(TAG, "BP2 RT error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2Info)
            .observeForever { event ->
                try {
                    sendEvent(mapOf("event" to "deviceInfo", "model" to event.model, "data" to event.data.toString()))
                } catch (e: Exception) { Log.e(TAG, "BP2 Info error", e) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2FileList)
            .observeForever { event ->
                try {
                    val files = extractFileList(event.data)
                    sendEvent(mapOf("event" to "fileList", "model" to event.model,
                        "deviceFamily" to "bp2", "files" to files))
                    maybeTriggerCatchUp(FileFamily.BP2, event.model, files)
                } catch (e: Exception) { Log.e(TAG, "BP2 FileList error", e) }
            }

        // OxyII family
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIISetTime)
            .observeForever { event ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to event.model, "subEvent" to "setTime",
                ))
            }

        // ════════════════════════════════════════════════════════════
        // Device-config + battery observers — wire format mirrors iOS.
        // Each handler reflects the SDK's family-specific struct into a
        // flat `deviceConfig` event so Dart sees a stable shape across
        // platforms. See lib/src/models/device_control.dart for the
        // typed view (DeviceConfigEvent / BatteryInfo).
        // ════════════════════════════════════════════════════════════
        registerConfigObservers()
        registerBatteryObservers()
        registerAirBpObservers()

        // Encrypt verification (PC60FW family)
        LiveEventBus.get<InterfaceEvent>(EventMsgConst.Ble.EventBleDeviceEncryptVerificationCompleted)
            .observeForever { event ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to event.model, "subEvent" to "encryptVerified",
                ))
            }

        // ════════════════════════════════════════════════════════════
        // File-transfer events — progress / complete / error per family
        //
        // Wire format (consumed by Dart's BluetodevController):
        //   { event: 'fileReadProgress', model, deviceFamily, progress: 0..1 }
        //   { event: 'fileReadComplete', model, deviceFamily, fileName,
        //                                 size, content: <base64>, parsed: { ... } }
        //   { event: 'fileReadError',    model, deviceFamily, error }
        //
        // The `parsed` object holds family-specific best-effort fields
        // extracted from the Lepu SDK's parsed file struct. Raw bytes
        // (when the SDK exposes them) ride along in `content` so callers
        // can re-parse or persist without round-tripping through Dart.
        // ════════════════════════════════════════════════════════════
        registerFileTransferObservers()

        Log.d(TAG, "LiveEventBus observers registered")
    }

    // ───── helpers used by the file-transfer observers ─────────────────

    /** Convert a 0..100 (Int) or 0..1 (Float/Double) progress value to 0..1. */
    private fun normalizeProgress(raw: Any?): Double {
        val d = when (raw) {
            is Int    -> raw.toDouble()
            is Long   -> raw.toDouble()
            is Float  -> raw.toDouble()
            is Double -> raw
            else      -> return 0.0
        }
        return if (d > 1.0) (d / 100.0).coerceIn(0.0, 1.0) else d.coerceIn(0.0, 1.0)
    }

    /** Reflectively call `obj.getName()` and return the result (or null). */
    private fun reflectGet(obj: Any?, getter: String): Any? {
        if (obj == null) return null
        return try {
            obj.javaClass.getMethod(getter).invoke(obj)
        } catch (_: Throwable) {
            null
        }
    }

    /** Encode a byte-array (or null) as a base64 string for the wire format. */
    private fun bytesToBase64(arr: ByteArray?): String? = arr?.let {
        android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP)
    }

    /**
     * Type-safe extraction of a `fileList` payload. The Lepu SDK posts an
     * `ArrayList<String>` on every `EventXxxFileList` channel, but Java
     * generics are erased so a direct `as ArrayList<String>` triggers an
     * UNCHECKED_CAST warning. Filtering by `String` instance restores the
     * type guarantee at runtime with no behaviour change.
     */
    private fun extractFileList(data: Any?): ArrayList<String> {
        val list = data as? List<*> ?: return arrayListOf()
        return ArrayList(list.filterIsInstance<String>())
    }

    /**
     * Build the `parsed` map of a fileReadComplete event for a given family.
     * Best-effort: every getter is reflected so a vendor SDK update that
     * removes a field doesn't break the whole event.
     */
    private fun parsedFileMap(family: String, fileObj: Any): Map<String, Any?> {
        val getters: List<String> = when (family) {
            "bp2" -> listOf("getFileName", "getType", "getContent")
            "er1", "er2" -> listOf("getFileName", "getContent")
            "oxy" -> listOf(
                "getFileType", "getFileVersion", "getRecordingTime",
                "getSpo2List", "getPrList", "getMotionList",
                "getAvgSpo2", "getAsleepTime", "getAsleepTimePercent",
                "getBytes",
            )
            "oxyII" -> listOf(
                "getFileType", "getFileVersion", "getDeviceModel",
                "getStartTime", "getRecordingTime", "getInterval",
                "getSpo2List", "getPrList", "getMotionList",
                "getAvgSpo2", "getMinSpo2", "getAvgHr",
                "getStepCounter", "getO2Score",
                "getDropsTimes3Percent", "getDropsTimes4Percent",
                "getDropsTimes90Percent", "getDurationTime90Percent",
                "getPercentLessThan90", "getRemindHrs", "getRemindsSpo2",
                "getInterval", "getCheckSum", "getMagic", "getSize",
                "getChannelType", "getChannelBytes", "getPointBytes",
                "getBytes",
            )
            "pf10aw1" -> listOf(
                "getFileType", "getFileVersion", "getDeviceModel",
                "getStartTime", "getEndTime", "getInterval",
                "getSpo2List", "getPrList",
                "getCheckSum", "getMagic", "getSize",
                "getChannelType", "getChannelBytes", "getPointBytes",
            )
            else -> emptyList()
        }
        val out = mutableMapOf<String, Any?>()
        for (g in getters) {
            val v = reflectGet(fileObj, g) ?: continue
            // Lepu uses Java-bean naming: stripping "get" gives the property name.
            val key = g.removePrefix("get").replaceFirstChar { it.lowercase() }
            out[key] = when (v) {
                is ByteArray  -> bytesToBase64(v)
                is IntArray   -> v.toList()
                is ShortArray -> v.toList()
                is FloatArray -> v.toList()
                is List<*>    -> v
                else          -> v.toString()
            }
        }
        return out
    }

    private fun emitReadingProgress(family: String, model: Int, raw: Any?) {
        sendEvent(mapOf(
            "event" to "fileReadProgress",
            "deviceFamily" to family,
            "model" to model,
            "progress" to normalizeProgress(raw),
        ))
    }

    private fun emitReadComplete(family: String, model: Int, fileObj: Any) {
        try {
            val name = reflectGet(fileObj, "getFileName") as? String
            val content = reflectGet(fileObj, "getContent") as? ByteArray
                ?: reflectGet(fileObj, "getBytes")   as? ByteArray
                ?: reflectGet(fileObj, "getPointBytes") as? ByteArray
            sendEvent(mapOf(
                "event" to "fileReadComplete",
                "deviceFamily" to family,
                "model" to model,
                "fileName" to (name ?: ""),
                "size" to (content?.size ?: 0),
                "content" to bytesToBase64(content),
                "parsed" to parsedFileMap(family, fileObj),
            ))
        } catch (e: Exception) {
            Log.e(TAG, "$family file complete error", e)
            sendEvent(mapOf(
                "event" to "fileReadError",
                "deviceFamily" to family,
                "model" to model,
                "error" to (e.message ?: "unknown"),
            ))
        }
    }

    private fun emitReadError(family: String, model: Int, raw: Any?) {
        sendEvent(mapOf(
            "event" to "fileReadError",
            "deviceFamily" to family,
            "model" to model,
            "error" to (raw?.toString() ?: "unknown"),
        ))
    }

    /** Subscribe to every Lepu-SDK file-transfer event we forward to Dart. */
    private fun registerFileTransferObservers() {
        // ── ER1 family ────────────────────────────────────────────────
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1ReadingFileProgress)
            .observeForever { e -> emitReadingProgress("er1", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1ReadFileComplete)
            .observeForever { e -> emitReadComplete("er1", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1ReadFileError)
            .observeForever { e -> emitReadError("er1", e.model, e.data) }

        // ── ER2 family ────────────────────────────────────────────────
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2ReadingFileProgress)
            .observeForever { e -> emitReadingProgress("er2", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2ReadFileComplete)
            .observeForever { e -> emitReadComplete("er2", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2ReadFileError)
            .observeForever { e -> emitReadError("er2", e.model, e.data) }

        // ── BP2 family ────────────────────────────────────────────────
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2ReadingFileProgress)
            .observeForever { e -> emitReadingProgress("bp2", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2ReadFileComplete)
            .observeForever { e -> emitReadComplete("bp2", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2ReadFileError)
            .observeForever { e -> emitReadError("bp2", e.model, e.data) }

        // ── Oxy (legacy O2Ring) family ────────────────────────────────
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyReadingFileProgress)
            .observeForever { e -> emitReadingProgress("oxy", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyReadFileComplete)
            .observeForever { e -> emitReadComplete("oxy", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Oxy.EventOxyReadFileError)
            .observeForever { e -> emitReadError("oxy", e.model, e.data) }

        // ── OxyII family ──────────────────────────────────────────────
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIIGetFileList)
            .observeForever { e ->
                try {
                    val files = extractFileList(e.data)
                    sendEvent(mapOf("event" to "fileList",
                        "model" to e.model, "deviceFamily" to "oxyII", "files" to files))
                    maybeTriggerCatchUp(FileFamily.OXYII, e.model, files)
                } catch (ex: Exception) { Log.e(TAG, "OxyII FileList error", ex) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIIReadingFileProgress)
            .observeForever { e -> emitReadingProgress("oxyII", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIIReadFileComplete)
            .observeForever { e -> emitReadComplete("oxyII", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIIReadFileError)
            .observeForever { e -> emitReadError("oxyII", e.model, e.data) }

        // ── PF-10AW1 family (FOxi parents) ────────────────────────────
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1GetFileList)
            .observeForever { e ->
                try {
                    val files = extractFileList(e.data)
                    sendEvent(mapOf("event" to "fileList",
                        "model" to e.model, "deviceFamily" to "pf10aw1", "files" to files))
                    maybeTriggerCatchUp(FileFamily.PF10AW1, e.model, files)
                } catch (ex: Exception) { Log.e(TAG, "Pf10Aw1 FileList error", ex) }
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1ReadingFileProgress)
            .observeForever { e -> emitReadingProgress("pf10aw1", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1ReadFileComplete)
            .observeForever { e -> emitReadComplete("pf10aw1", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1ReadFileError)
            .observeForever { e -> emitReadError("pf10aw1", e.model, e.data) }
    }

    // ════════════════════════════════════════════════════════════════════
    // Device-config observers
    //
    // The Lepu SDK posts vendor-specific config structs through these
    // events; we reflect them into a flat map so Dart sees the same
    // `deviceConfig` wire format the iOS plugin emits.
    //
    // Notes on field naming:
    //   - We keep getter-derived names verbatim (e.g. `isSoundOn` →
    //     `soundOn`) so a one-to-one mapping with `ConfigField.name`
    //     round-trips losslessly through getDeviceConfig + setDeviceConfig.
    //   - OxyII / oxy2 publishes nested wrapper classes per setting;
    //     extractConfigFields drills into each via reflection.
    // ════════════════════════════════════════════════════════════════════

    private fun registerConfigObservers() {
        // BP2 family
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2GetConfig)
            .observeForever { e -> emitDeviceConfig("bp2", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2SetConfig)
            .observeForever { e ->
                // Re-emit the cached fields so consumers waiting on
                // deviceConfigStream see a write-acknowledged event too.
                emitDeviceConfig("bp2", e.model, e.data, ack = true)
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP2.EventBp2GetConfigError)
            .observeForever { e -> emitDeviceConfigError("bp2", e.model, e.data) }

        // BP3 family — same channel naming, different class (Bp3Config).
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP3.EventBp3GetConfig)
            .observeForever { e -> emitDeviceConfig("bp3", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP3.EventBp3SetConfig)
            .observeForever { e -> emitDeviceConfig("bp3", e.model, e.data, ack = true) }

        // ER1 family
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1GetConfig)
            .observeForever { e -> emitDeviceConfig("er1", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1SetConfig)
            .observeForever { e -> emitDeviceConfig("er1", e.model, e.data, ack = true) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER1.EventEr1GetConfigError)
            .observeForever { e -> emitDeviceConfigError("er1", e.model, e.data) }

        // ER2 family
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2GetConfig)
            .observeForever { e -> emitDeviceConfig("er2", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2SetConfig)
            .observeForever { e -> emitDeviceConfig("er2", e.model, e.data, ack = true) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.ER2.EventEr2GetConfigError)
            .observeForever { e -> emitDeviceConfigError("er2", e.model, e.data) }

        // OxyII family — uses the `oxy2.Config` shape with nested wrappers.
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIIGetConfig)
            .observeForever { e -> emitDeviceConfig("oxyII", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIISetConfig)
            .observeForever { e -> emitDeviceConfig("oxyII", e.model, e.data, ack = true) }

        // PF10AW1 family
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1GetConfig)
            .observeForever { e -> emitDeviceConfig("pf10aw1", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.Pf10Aw1.EventPf10Aw1SetConfig)
            .observeForever { e -> emitDeviceConfig("pf10aw1", e.model, e.data, ack = true) }
    }

    private fun registerBatteryObservers() {
        // The Lepu SDK only exposes EventXxxGetBattery for the small
        // subset of families whose protocol has an on-demand battery
        // query (OxyII / BP3 / AirBP / AP20 / SP20 / LEM / PC80B).
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.OxyII.EventOxyIIGetBattery)
            .observeForever { e -> emitBatteryEvent("oxyII", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.BP3.EventBp3GetBattery)
            .observeForever { e -> emitBatteryEvent("bp3", e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpGetBattery)
            .observeForever { e -> emitBatteryEvent("airbp", e.model, e.data) }
    }

    // ════════════════════════════════════════════════════════════════════
    // AirBP / SmartBP observers
    //
    // Wire format mirrors the iOS plugin's `handleAirBPFrameCmd:`
    // implementation so a Dart consumer can subscribe to the same
    // `rtData` shape on either platform:
    //
    //   - rt.data    → `rtData` { measureType: "bp_measuring", pressure, pulseWave }
    //   - rt.state   → `rtData` { measureType: "bp_status", status }
    //   - rt.result  → `rtData` { measureType: "bp_result", sys, dia, mean, pr,
    //                              state, timestamp }
    //   - get.info   → `deviceInfo`
    //   - get.config → `deviceConfig` (family="airbp")
    //   - set.config → `deviceConfig` (family="airbp", ack=true)
    //   - reset      → `connectionState` subEvent="reset"
    //   - factoryReset → `connectionState` subEvent="factoryReset"
    //
    // The SDK posts a Bluetooth-specific payload type per channel; we
    // reflect rather than cast so an SDK version bump that reshapes the
    // struct doesn't break the bridge.
    // ════════════════════════════════════════════════════════════════════

    private fun registerAirBpObservers() {
        val mainFam = "airbp"

        // rt.data — pressure / pulse pair posted while the cuff inflates.
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpRtData)
            .observeForever { e ->
                val pressure = reflectInt(e.data, "getPressure")
                    ?: reflectInt(e.data, "getStaticPressure")
                val pulseWave = reflectInt(e.data, "getPulse")
                    ?: reflectInt(e.data, "getPulseWave")
                sendEvent(mapOf(
                    "event"        to "rtData",
                    "deviceType"   to "bp",
                    "deviceFamily" to mainFam,
                    "sdk"          to "lepu",
                    "model"        to e.model,
                    "measureType"  to "bp_measuring",
                    "pressure"     to (pressure?.let { it / 100.0 }),
                    "pressureRaw"  to pressure,
                    "pulseWave"    to pulseWave,
                    "pulseWaveRaw" to pulseWave,
                ))
            }

        // rt.state — running-status enum (idle / inflating / deflating / done).
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpRtState)
            .observeForever { e ->
                val status = when (val d = e.data) {
                    is Int -> d
                    is Number -> d.toInt()
                    else -> reflectInt(d, "getState") ?: reflectInt(d, "getStatus")
                }
                sendEvent(mapOf(
                    "event"        to "rtData",
                    "deviceType"   to "bp",
                    "deviceFamily" to mainFam,
                    "sdk"          to "lepu",
                    "model"        to e.model,
                    "measureType"  to "bp_status",
                    "status"       to status,
                ))
            }

        // rt.result — final SBP/DBP/MAP/PR. Lepu uses `RtResult`; struct
        // mirrors iOS payload bytes 8..15.
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpRtResult)
            .observeForever { e ->
                val r = e.data ?: return@observeForever
                val y = reflectInt(r, "getYear") ?: 0
                val mo = reflectInt(r, "getMonth") ?: 0
                val d = reflectInt(r, "getDay") ?: 0
                val h = reflectInt(r, "getHour") ?: 0
                val mi = reflectInt(r, "getMinute") ?: 0
                val s = reflectInt(r, "getSecond") ?: 0
                val ts = "%04d-%02d-%02d %02d:%02d:%02d".format(y, mo, d, h, mi, s)
                sendEvent(mapOf(
                    "event"        to "rtData",
                    "deviceType"   to "bp",
                    "deviceFamily" to mainFam,
                    "sdk"          to "lepu",
                    "model"        to e.model,
                    "measureType"  to "bp_result",
                    "sys"          to reflectInt(r, "getSys"),
                    "dia"          to reflectInt(r, "getDia"),
                    "mean"         to reflectInt(r, "getMean"),
                    "pr"           to reflectInt(r, "getPr"),
                    "state"        to reflectInt(r, "getStateCode"),
                    "timestamp"    to ts,
                ))
            }

        // get.info — emit a `deviceInfo` event with the reflected struct.
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpGetInfo)
            .observeForever { e ->
                val payload = mutableMapOf<String, Any?>(
                    "event" to "deviceInfo",
                    "sdk"   to "lepu",
                    "model" to e.model,
                )
                e.data?.let { payload.putAll(extractConfigFields(it)) }
                sendEvent(payload)
            }

        // get.config / set.config — flat `deviceConfig` events (family=airbp).
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpGetConfig)
            .observeForever { e -> emitDeviceConfig(mainFam, e.model, e.data) }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpSetConfig)
            .observeForever { e -> emitDeviceConfig(mainFam, e.model, e.data, ack = true) }

        // reset / factory reset — surface as connection sub-events for
        // parity with the existing UI hooks.
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpReset)
            .observeForever { e ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to e.model, "subEvent" to "reset",
                ))
            }
        LiveEventBus.get<InterfaceEvent>(InterfaceEvent.AirBP.EventAirBpFactoryReset)
            .observeForever { e ->
                sendEvent(mapOf(
                    "event" to "connectionState", "state" to "connected",
                    "model" to e.model, "subEvent" to "factoryReset",
                ))
            }
    }

    /// Reflect every getter on the SDK's config object into a flat map.
    /// Boolean getters are normalised from `isFoo()` → `foo` so the
    /// field name matches `ConfigField.name`.
    ///
    /// `ack` distinguishes a "read response" from a "write
    /// acknowledged" emission. Dart consumers can ignore the flag for
    /// the simple read flow.
    private fun emitDeviceConfig(family: String, model: Int, data: Any?,
                                 ack: Boolean = false) {
        if (data == null) return
        val fields = extractConfigFields(data)
        val payload = mutableMapOf<String, Any?>(
            "event"  to "deviceConfig",
            "family" to family,
            "model"  to model,
        )
        if (ack) payload["ack"] = true
        payload.putAll(fields)
        sendEvent(payload)
    }

    private fun emitDeviceConfigError(family: String, model: Int, data: Any?) {
        sendEvent(mapOf(
            "event"  to "deviceConfigError",
            "family" to family,
            "model"  to model,
            "error"  to (data?.toString() ?: "unknown"),
        ))
    }

    /// Reflect every `getXxx()` / `isXxx()` getter on the supplied
    /// config object into a Map keyed by the bean-property name.
    /// Nested oxy2.Config wrappers (Spo2Switch/HrLow/…) are unwrapped
    /// to their inner `val` so the map stays flat.
    private fun extractConfigFields(obj: Any): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        for (m in obj.javaClass.methods) {
            if (m.parameterCount != 0) continue
            val name = m.name
            val isGetter = name.length > 3 && name.startsWith("get") &&
                Character.isUpperCase(name[3])
            val isIs = name.length > 2 && name.startsWith("is") &&
                Character.isUpperCase(name[2])
            if (!isGetter && !isIs) continue
            // Skip Object-defined accessors that ride along on every class.
            if (name == "getClass") continue
            val key = if (isGetter) {
                name.substring(3).replaceFirstChar { it.lowercase() }
            } else {
                // `isFoo` → `foo` so it matches the consumer's field name.
                name.substring(2).replaceFirstChar { it.lowercase() }
            }
            val raw = try { m.invoke(obj) } catch (_: Throwable) { null }
            // Unwrap oxy2.Config nested wrappers — every one of them
            // exposes a single `getVal()` int getter that holds the
            // setting value.
            val flattened = if (raw != null &&
                raw.javaClass.name.startsWith("com.lepu.blepro.ext.oxy2.Config\$")) {
                try { raw.javaClass.getMethod("getVal").invoke(raw) } catch (_: Throwable) { raw }
            } else raw
            if (flattened is Int || flattened is Boolean || flattened is String ||
                flattened is Long || flattened is Double || flattened == null) {
                out[key] = flattened
            } else if (flattened is Number) {
                out[key] = flattened.toInt()
            }
            // Other shapes (byte[]) are skipped — the consumer doesn't
            // get to see calibration blobs through this flat map.
        }
        return out
    }

    private fun emitBatteryEvent(family: String, model: Int, data: Any?) {
        // Each family's GetBattery event posts a different concrete
        // type, so we reflect rather than cast. Common field names:
        //   getPercent() : Int     — both OxyII / BP3
        //   getStatus()  : Int     — OxyII (battery state enum)
        //   getState()   : Int     — BP3
        //   getVoltage() : Int     — some firmwares
        val percent = reflectInt(data, "getPercent")
        val state = reflectInt(data, "getState") ?: reflectInt(data, "getStatus")
        val voltage = reflectInt(data, "getVoltage")
        sendEvent(mapOf(
            "event"   to "battery",
            "family"  to family,
            "model"   to model,
            "percent" to percent,
            "state"   to state,
            "voltage" to voltage,
        ))
    }

    private fun reflectInt(obj: Any?, getter: String): Int? {
        if (obj == null) return null
        return try {
            val v = obj.javaClass.getMethod(getter).invoke(obj)
            (v as? Number)?.toInt()
        } catch (_: Throwable) {
            null
        }
    }
}
