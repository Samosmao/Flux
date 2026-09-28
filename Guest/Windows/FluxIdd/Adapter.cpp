#include "FluxIdd.h"
NTSTATUS FluxIddInitializeAdapter(WDFDEVICE device) {
    IDDCX_ADAPTER_CAPS caps = {}; caps.Size = sizeof(caps); caps.MaxMonitorsSupported = 1;
    caps.EndPointDiagnostics.Size = sizeof(caps.EndPointDiagnostics);
    caps.EndPointDiagnostics.GammaSupport = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    caps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;
    caps.EndPointDiagnostics.pEndPointFriendlyName = kFluxIddFriendlyName;
    caps.EndPointDiagnostics.pEndPointManufacturerName = kFluxIddManufacturer;
    caps.EndPointDiagnostics.pEndPointModelName = L"Flux IddCx v0";
    IDDCX_ENDPOINT_VERSION version = {}; version.Size = sizeof(version); version.MajorVer = 0; version.MinorVer = 1;
    caps.EndPointDiagnostics.pFirmwareVersion = &version; caps.EndPointDiagnostics.pHardwareVersion = &version;
    WDF_OBJECT_ATTRIBUTES attributes; WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    IDARG_IN_ADAPTER_INIT input = {}; input.WdfDevice = device; input.pCaps = &caps; input.ObjectAttributes = &attributes;
    IDARG_OUT_ADAPTER_INIT output = {}; NTSTATUS status = IddCxAdapterInitAsync(&input, &output);
    if (NT_SUCCESS(status)) FluxGetDeviceContext(device)->adapter = output.AdapterObject;
    return status;
}
NTSTATUS FluxIddAdapterInitFinished(IDDCX_ADAPTER adapter, const IDARG_IN_ADAPTER_INIT_FINISHED* args) {
    return NT_SUCCESS(args->AdapterInitStatus) ? FluxIddCreateAndArriveMonitor(adapter) : args->AdapterInitStatus;
}
NTSTATUS FluxIddAdapterCommitModes(IDDCX_ADAPTER, const IDARG_IN_COMMITMODES*) { return STATUS_SUCCESS; }
