#include "FluxIdd.h"
extern "C" BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }
extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath) {
    WDF_DRIVER_CONFIG config; WDF_DRIVER_CONFIG_INIT(&config, FluxIddDeviceAdd);
    WDF_OBJECT_ATTRIBUTES attributes; WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    return WdfDriverCreate(driverObject, registryPath, &attributes, &config, WDF_NO_HANDLE);
}
NTSTATUS FluxIddDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT deviceInit) {
    WDF_PNPPOWER_EVENT_CALLBACKS power; WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&power);
    power.EvtDeviceD0Entry = FluxIddDeviceD0Entry; WdfDeviceInitSetPnpPowerEventCallbacks(deviceInit, &power);
    IDD_CX_CLIENT_CONFIG config; IDD_CX_CLIENT_CONFIG_INIT(&config);
    config.EvtIddCxAdapterInitFinished = FluxIddAdapterInitFinished;
    config.EvtIddCxAdapterCommitModes = FluxIddAdapterCommitModes;
    config.EvtIddCxMonitorGetDefaultDescriptionModes = FluxIddMonitorGetDefaultModes;
    config.EvtIddCxMonitorQueryTargetModes = FluxIddMonitorQueryTargetModes;
    config.EvtIddCxMonitorAssignSwapChain = FluxIddMonitorAssignSwapChain;
    config.EvtIddCxMonitorUnassignSwapChain = FluxIddMonitorUnassignSwapChain;
    NTSTATUS status = IddCxDeviceInitConfig(deviceInit, &config); if (!NT_SUCCESS(status)) return status;
    WDF_OBJECT_ATTRIBUTES attributes; WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, FluxDeviceContext);
    WDFDEVICE device = nullptr; status = WdfDeviceCreate(&deviceInit, &attributes, &device); if (!NT_SUCCESS(status)) return status;
    auto* context = FluxGetDeviceContext(device); context->device = device; context->adapter = {};
    return IddCxDeviceInitialize(device);
}
NTSTATUS FluxIddDeviceD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE) { return FluxIddInitializeAdapter(device); }
