# FluxIdd

Build-ready Windows 11 ARM64 UMDF IddCx skeleton; it has not been installed into the VM.

## Fixed contract

- PnP ID: `ROOT\FLUX_IDD`
- Name: `Flux Virtual Display Adapter`; manufacturer: `Flux`
- One IddCx adapter and one monitor
- Exactly `800x600 @ 60 Hz` and `1280x720 @ 60 Hz`
- Standard IddCx 32-bit DXGI desktop composition path; no HDR, VRR, PCI, transport, or multi-monitor support.

The monitor is EDID-less by design; the two modes are reported by the default-monitor and target-mode callbacks.

## Intentional limitation

`SwapChain.cpp` declines assigned scanouts. Do not install this as a usable desktop path. The next stage replaces that stub with:

`IddCx swapchain frame -> Flux transport -> host shared surface -> Metal`

RAMFB/GOP and the current Metal path are not referenced or changed.

## Windows build prerequisites

Install Visual Studio 2022 (C++ ARM64 tools), a matching Windows 11 SDK, and the current Windows 11 WDK containing UMDF 2, `iddcx.h`, `IddCxStub.lib`, and `WindowsUserModeDriver10.0`.

Run from a Windows Developer Command Prompt:

```powershell
msbuild .\FluxIdd.sln /m /p:Configuration=Debug /p:Platform=ARM64
```

The ARM64 settings track Microsoft's current IddSample: UMDF 2.25 and IddCx 1.4. Verify installed WDK IddCx support before building.

## Signing later

No signing was performed. Later development installation requires a test certificate, catalog creation/signing, and—only if required by the test workflow—test-signing policy in the VM. Production signing is out of scope.

## References

- https://learn.microsoft.com/en-us/samples/microsoft/windows-driver-samples/indirect-display-driver-sample/
- https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx-objects
