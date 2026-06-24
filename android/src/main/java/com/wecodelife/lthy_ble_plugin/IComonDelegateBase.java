package com.wecodelife.lthy_ble_plugin;

import java.util.List;

import cn.icomon.icdevicemanager.ICDeviceManagerDelegate;
import cn.icomon.icdevicemanager.model.data.ICCoordData;
import cn.icomon.icdevicemanager.model.data.ICFoodInfo;
import cn.icomon.icdevicemanager.model.data.ICKitchenScaleData;
import cn.icomon.icdevicemanager.model.data.ICRulerData;
import cn.icomon.icdevicemanager.model.data.ICSkipData;
import cn.icomon.icdevicemanager.model.data.ICWeightCenterData;
import cn.icomon.icdevicemanager.model.data.ICWeightData;
import cn.icomon.icdevicemanager.model.data.ICWeightHistoryData;
import cn.icomon.icdevicemanager.model.device.ICDevice;
import cn.icomon.icdevicemanager.model.device.ICDeviceInfo;
import cn.icomon.icdevicemanager.model.device.ICUserInfo;
import cn.icomon.icdevicemanager.model.other.ICConstant;

public class IComonDelegateBase implements ICDeviceManagerDelegate {

    @Override
    public void onInitFinish(boolean bSuccess) {}

    @Override
    public void onBleState(ICConstant.ICBleState state) {}

    @Override
    public void onDeviceConnectionChanged(ICDevice device, ICConstant.ICDeviceConnectState state) {}

    @Override
    public void onNodeConnectionChanged(ICDevice device, int nodeId, ICConstant.ICDeviceConnectState state) {}

    @Override
    public void onReceiveWeightData(ICDevice device, ICWeightData data) {}

    @Override
    public void onReceiveKitchenScaleData(ICDevice device, ICKitchenScaleData data) {}

    @Override
    public void onReceiveKitchenScaleHistoryData(ICDevice icDevice, List<ICKitchenScaleData> list) {}

    @Override
    public void onReceiveKitchenScaleUnitChanged(ICDevice device, ICConstant.ICKitchenScaleUnit unit) {}

    @Override
    public void onReceiveKitchenScaleCommonFoods(ICDevice icDevice, List<ICFoodInfo> list) {}

    @Override
    public void onReceiveCoordData(ICDevice device, ICCoordData data) {}

    @Override
    public void onReceiveRulerData(ICDevice device, ICRulerData data) {}

    @Override
    public void onReceiveRulerHistoryData(ICDevice icDevice, ICRulerData icRulerData) {}

    @Override
    public void onReceiveWeightCenterData(ICDevice icDevice, ICWeightCenterData data) {}

    @Override
    public void onReceiveWeightUnitChanged(ICDevice icDevice, ICConstant.ICWeightUnit unit) {}

    @Override
    public void onReceiveRulerUnitChanged(ICDevice icDevice, ICConstant.ICRulerUnit unit) {}

    @Override
    public void onReceiveRulerMeasureModeChanged(ICDevice icDevice, ICConstant.ICRulerMeasureMode mode) {}

    @Override
    public void onReceiveMeasureStepData(ICDevice icDevice, ICConstant.ICMeasureStep step, Object data2) {}

    @Override
    public void onReceiveWeightHistoryData(ICDevice icDevice, ICWeightHistoryData icWeightHistoryData) {}

    @Override
    public void onReceiveSkipData(ICDevice icDevice, ICSkipData data) {}

    @Override
    public void onReceiveHistorySkipData(ICDevice icDevice, ICSkipData icSkipData) {}

    @Override
    public void onReceiveBattery(ICDevice device, int battery, Object ext) {}

    @Override
    public void onReceiveUpgradePercent(ICDevice icDevice, ICConstant.ICUpgradeStatus icUpgradeStatus, int i) {}

    @Override
    public void onReceiveDeviceInfo(ICDevice icDevice, ICDeviceInfo icDeviceInfo) {}

    @Override
    public void onReceiveDebugData(ICDevice icDevice, int i, Object o) {}

    @Override
    public void onReceiveConfigWifiResult(ICDevice icDevice, ICConstant.ICConfigWifiResultType icConfigWifiResultType, Object o) {}

    @Override
    public void onReceiveHR(ICDevice device, int hr) {}

    @Override
    public void onReceiveUserInfo(ICDevice device, ICUserInfo userInfo) {}

    @Override
    public void onReceiveUserInfoList(ICDevice icDevice, List<ICUserInfo> list) {}

    @Override
    public void onReceiveRSSI(ICDevice device, int rssi) {}

    @Override
    public void onReceiveDeviceLightSetting(ICDevice icDevice, Object o) {}

    @Override
    public void onReceiveScanWifiInfo_W(ICDevice icDevice, String s, Integer integer, Integer integer1) {}

    @Override
    public void onReceiveCurrentWifiInfo_W(ICDevice icDevice, Integer integer, String s, String s1, Integer integer1) {}

    @Override
    public void onReceiveBindState_W(ICDevice icDevice, Integer integer) {}

    @Override
    public void onReceiveCurrentPage(ICDevice icDevice, Integer integer) {}
}
