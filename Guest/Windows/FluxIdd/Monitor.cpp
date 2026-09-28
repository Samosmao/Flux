#include "FluxIdd.h"
const FluxIddMode kFluxIddModes[2] = { {800, 600, 60}, {1280, 720, 60} };
static void FillSignalInfo(DISPLAYCONFIG_VIDEO_SIGNAL_INFO* signal, const FluxIddMode& mode, bool monitorMode) {
    signal->totalSize.cx = signal->activeSize.cx = mode.width; signal->totalSize.cy = signal->activeSize.cy = mode.height;
    signal->AdditionalSignalInfo.vSyncFreqDivider = monitorMode ? 0 : 1; signal->AdditionalSignalInfo.videoStandard = 255;
    signal->vSyncFreq.Numerator = mode.refreshHz; signal->vSyncFreq.Denominator = 1;
    signal->hSyncFreq.Numerator = mode.refreshHz * mode.height; signal->hSyncFreq.Denominator = 1;
    signal->scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    signal->pixelRate = static_cast<UINT64>(mode.refreshHz) * mode.width * mode.height;
}
IDDCX_MONITOR_MODE FluxIddMakeMonitorMode(const FluxIddMode& mode) { IDDCX_MONITOR_MODE out = {}; out.Size = sizeof(out); out.Origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER; FillSignalInfo(&out.MonitorVideoSignalInfo, mode, true); return out; }
IDDCX_TARGET_MODE FluxIddMakeTargetMode(const FluxIddMode& mode) { IDDCX_TARGET_MODE out = {}; out.Size = sizeof(out); FillSignalInfo(&out.TargetVideoSignalInfo.targetVideoSignalInfo, mode, false); return out; }
NTSTATUS FluxIddCreateAndArriveMonitor(IDDCX_ADAPTER adapter) {
    WDF_OBJECT_ATTRIBUTES attributes; WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, FluxMonitorContext);
    IDARG_IN_MONITORCREATE input = {}; input.Size = sizeof(input); input.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_OTHER;
    input.ConnectorIndex = 0; input.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_UNINITIALIZED; input.ObjectAttributes = &attributes;
    IDARG_OUT_MONITORCREATE output = {}; NTSTATUS status = IddCxMonitorCreate(adapter, &input, &output); if (!NT_SUCCESS(status)) return status;
    FluxGetMonitorContext(output.MonitorObject)->monitor = output.MonitorObject;
    IDARG_OUT_MONITORARRIVAL arrival = {}; return IddCxMonitorArrival(output.MonitorObject, &arrival);
}
NTSTATUS FluxIddMonitorGetDefaultModes(IDDCX_MONITOR, const IDARG_IN_GETMONITORDESCRIPTIONMODES* input, IDARG_OUT_GETMONITORDESCRIPTIONMODES* output) {
    output->DefaultMonitorModeBufferOutputCount = static_cast<UINT>(kFluxIddModeCount);
    if (input->DefaultMonitorModeBufferInputCount >= kFluxIddModeCount) for (size_t i = 0; i < kFluxIddModeCount; ++i) input->pDefaultMonitorModes[i] = FluxIddMakeMonitorMode(kFluxIddModes[i]);
    return STATUS_SUCCESS;
}
NTSTATUS FluxIddMonitorQueryTargetModes(IDDCX_MONITOR, const IDARG_IN_QUERYTARGETMODES* input, IDARG_OUT_QUERYTARGETMODES* output) {
    output->TargetModeBufferOutputCount = static_cast<UINT>(kFluxIddModeCount);
    if (input->TargetModeBufferInputCount >= kFluxIddModeCount) for (size_t i = 0; i < kFluxIddModeCount; ++i) input->pTargetModes[i] = FluxIddMakeTargetMode(kFluxIddModes[i]);
    return STATUS_SUCCESS;
}
