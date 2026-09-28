#include "FluxIdd.h"
NTSTATUS FluxIddMonitorAssignSwapChain(IDDCX_MONITOR, const IDARG_IN_SETSWAPCHAIN* args) {
    // Future implementation: IddCx frame -> Flux transport -> shared surface -> Metal.
    // This build-only skeleton deliberately declines a scanout it cannot consume.
    WdfObjectDelete(args->hSwapChain); return STATUS_SUCCESS;
}
NTSTATUS FluxIddMonitorUnassignSwapChain(IDDCX_MONITOR) { return STATUS_SUCCESS; }
