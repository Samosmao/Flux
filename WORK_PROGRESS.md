Hypothesis: PCIe extended-config probes alias into the Type 0 header because NVMe masks ECAM offsets with 0xFF.
Patch: Return zero and ignore writes for unsupported offsets 0x100...0xFFF.
Result: Source type-check passed; full app build is blocked locally by the missing Xcode Metal Toolchain.
Next: Validate partial Type 0 config accesses, especially PMCSR byte/word accesses.

Hypothesis: Partial ECAM reads/writes can cross BAR dword boundaries and must not be interpreted as full dword accesses.
Patch: Read config one byte at a time and merge partial BAR/Command writes.
Result: Source type-check and full Debug build passed.
Next: Run the freshly built, signed app and compare the Windows PCI/PnP trace; direct executable launch exited before VM output, while the existing UI launch is a different Xcode build.

Hypothesis: Periodic canceled-run sampler output is obscuring the PCI/PnP evidence.
Patch: Gate sampler register/framebuffer/screenshot diagnostics behind FLUX_VERBOSE_SAMPLER=1 without changing framebuffer handling.
Result: Pending signed Xcode Debug run.
Next: Capture the firmware-to-Windows PCI/NVMe sequence and compare it with the prior D3hot pattern.

Hypothesis: A malformed PM or PCIe capability makes Windows stop the function before StorNVMe binds.
Patch: None; strict capability audit only.
Result: PM=0x0003 (PM 1.2, no unsupported D1/D2/PME); PCIe=0x0002 (v2 Endpoint, no slot); DeviceCaps=0x00000001; LinkCaps=0x00010011; LinkStatus=0x1011. All fields are valid. Signed trace still ends 0x407 -> 0x400 -> PMCSR D3hot with no Windows NVMe MMIO.
Next: Audit root-bridge ACPI resource windows and _PRT against the exact BAR/ECAM ranges.

Hypothesis: _OSC falsely grants Windows native PCIe controls that Flux does not implement, leading PnP to stop the endpoint.
Patch: _OSC now masks all unsupported PCIe native-control bits, sets the control-masked status for non-query requests, and returns an empty granted-control mask.
Result: Pending signed Xcode Debug run.
Next: Compare the Windows 0x407 -> 0x400 -> D3hot path and NVMe MMIO trace after the ownership correction.

Hypothesis: The Debug display fault is a stale framebuffer pointer after guest-RAM teardown.
Patch: Invalidate the shared framebuffer before guest RAM cleanup.
Result: The pointer was also rejected by Xcode's Metal capture layer while the VM was live; the teardown guard is correct but insufficient for this run.
Next: Stage live framebuffer pixels in ordinary process memory for Metal, then resume the _OSC PCI/PnP comparison.

Hypothesis: Windows/firmware handoff requires PSCI SYSTEM_RESET, but Flux currently terminates the VM on every guest reset.
Patch: Preserve the reset request through the exit handler and recreate the vCPU/GIC execution state while retaining guest RAM, flash, and disks.
Result: First signed run reached PSCI_SYSTEM_RESET, but re-creating the GIC failed with Hypervisor.framework status -85377022; the framework keeps that GIC attached for the VM lifetime.
Next: Retain the existing GIC and recreate only the vCPU state, then validate reboot continuity and distinguish the firmware and Windows NVMe initialization sequences.

Hypothesis: PSCI SYSTEM_RESET needs only fresh vCPU state because Hypervisor.framework retains the VM GIC.
Patch: Retain the existing GIC; recreate and initialize only the vCPU plus its GIC/timer interface.
Result: Signed Debug run now survives the reset and continues executing (about one core, 1.13 GB guest committed) with live framebuffer and no runtime error. The prior 0x407 -> 0x400 -> D3hot sequence is absent, but only the firmware NVMe Controller Enabled event is currently visible; no second Windows NVMe enable event yet.
Next: Capture focused post-reset PCI config/PnP evidence and determine why Windows has not issued its own CAP/CSTS/AQA/ASQ/ACQ sequence.

Hypothesis: Windows has retained the function but StorNVMe binding evidence is only in transient SetupAPI/PnP memory state.
Patch: Add one deferred post-reset PNP_LOG scan, capped at 1.5 GiB and narrowed to PCI identity, stornvme/storport, driver/service, and problem-status markers.
Result: The corrected signed capture proves the inbox `stornvme` service/package is present and contains an explicit `VEN_8086&DEV_0953` match for Standard NVM Express Controller. It captured package/registry material, not a `PCI\\VEN_8086&DEV_0953` device instance, AddDevice, StartDevice, CM_PROB, or resource outcome; binding stage remains unclassified.
Next: The 60-second capture still showed only static driver-store/service material, not an actual device-instance record. Logging-only adjustment: probe one 768 MiB active upper-memory window (guest 0x60000000), rather than repeatedly scanning all 4 GiB. No PCI, ACPI, or NVMe behavior changed.

Hypothesis: Reset-relative time is not a reliable proxy for the post-reset Windows PCI/PnP pass.
Patch: The bounded PNP_LOG scan is now armed only after reset and triggered by the post-reset PCI Command write that restores MSE/BME (0x0007). The scan remains bounded to guest 0x60000000..0x90000000.
Result: The prior upper-window run fired successfully but had no PCI/NVMe/PnP marker, so it provides no device-start evidence (classification H only).
Next: Signed rerun with the PCI-enumeration-triggered scanner; classify only a device-instance-context result.

Hypothesis: DSDT AML corruption caused by missing MethodOp 0x14 in runtime PCI0._OSC, mismatched table header length (482 vs 481), and incorrect checksum/loader size causes ACPI parsing or OS negotiation failure during kernel handoff.
Patch: Prepended 0x14 to runtime _OSC, adjusted enclosing Scope/Device PkgLength fields (0x4D 0x1B, 0x45 0x0E), computed DSDT header length and checksum dynamically over dsdtData, and passed dsdtFinalLength to fw_cfg table-loader command 7.
Static validation: Disassembled runtime AML with iasl -d (/tmp/runtime_dsdt.aml) with 0 errors/0 warnings; decoded clean Device(PCI0), _CRS, _PRT, and Method(_OSC, 4, NotSerialized); exact 482 bytes; byte-for-byte match against reference dsdt.aml.
VM result: EDK2 loaded ACPI tables, configured 800x600 RAMFB, and booted Windows from NVMe NS2. Device maintained BAR0=0x10000000, Command=0x0007 (MSE=1, BME=1), PMCSR=0x0000 (D0); prior 0x0407->0x0400->D3hot sequence remained absent. Following guest PSCI reset, vCPU entered EDK2 reset loop at PC 0x20a30; no second Windows-side NVMe initialization sequence (CAP/CSTS/AQA/ASQ/ACQ, CC.EN=1) observed.
Next: Restore DTB magic/structure at guest RAM 0x40000000 across PSCI SYSTEM_RESET to allow EDK2 reboot completion, or identify whether Windows bootloader triggers reset due to missing boot device context.

Hypothesis: EDK2 hangs in CpuDeadLoop at PC 0x20a30 on PSCI_SYSTEM_RESET because the platform DTB at GPA 0x40000000 was overwritten by the guest OS during early boot and was not restored across warm reset, causing fdt_check_header() to fail with FDT_ERR_BADMAGIC.
Patch: In FluxVM.swift:resetGuestExecution(), invoked memory.loadDeviceTree() to restore the 2,067-byte DTB at 0x40000000 and explicitly set cpu.setRegister(HV_REG_X0, value: memory.guestBase) before restarting execution.
Static validation: Verified memory.loadDeviceTree() loads 2,067 bytes with magic 0xD00DFEED to 0x40000000; verified Xcode Debug build and codesigning succeed cleanly with zero warnings/errors.
VM result: EDK2 reboot dead-loop at PC 0x20a30 is completely resolved. EDK2 survives PSCI_SYSTEM_RESET, restarts from SEC/PEI, reinitializes RAMFB and NVMe, and successfully boots Boot0002 repeatedly through consecutive resets without hanging.
Next: Determine why bootaa64.efi requests cold reset (ResetSystem) instead of continuing to WinPE GUI/kernel handoff.

Hypothesis: Windows 11 ARM64 boot halts with Stop code ACPI_BIOS_ERROR (0xA5) due to an ACPI table discovery/linkage defect during kernel early initialization.
Patch: Added non-invasive BugCheck scanner in FluxVM.swift to inspect guest memory on PSCI reset; no functional ACPI/PCI/NVMe modifications made.
Static validation: Disassembled all runtime tables with iasl -d (DSDT 482B, FADT 276B, MADT 166B, GTDT 104B, SPCR 90B, MCFG 60B); zero errors/warnings. Found RSDP.RsdtAddress is hard-coded to 0x00000000 with no 32-bit RSDT generated.
VM result: Captured KiBugCheckData at guest GPA 0x100dbb9a0: BugCheckCode=0xA5, Arg1=0x11 (ACPI mode entry failure), Arg2=0x3 (cannot load RSDT/XSDT table), Arg3=0x0, Arg4=0x0.
Next: Provide a standard 32-bit RSDT alongside XSDT in FluxACPI.swift, populating rsdp.RsdtAddress via fw_cfg linker-loader.

Hypothesis: Providing a standard 32-bit RSDT alongside XSDT in the fw_cfg ACPI payload and pointing RSDP.RsdtAddress to it satisfies Windows 11 early root table discovery and resolves BugCheck 0xA5 (0x11, 0x03).
Patch: Emitted 56-byte standard RSDT (FADT, MADT, GTDT, SPCR, MCFG), added loader ADD_POINTER relocations for all 5 entries (size 4), added ADD_CHECKSUM for RSDT, and added ADD_POINTER for RSDP.RsdtAddress (offset 16, size 4).
Static validation: Disassembled runtime RSDT and XSDT with iasl -d with 0 errors/0 warnings; verified RSDP checksums (standard sum=0, extended sum=0), RSDT length 56 bytes, checksum sum=0, five valid 32-bit entries matching XSDT 64-bit entries, FADT X_DSDT -> 482B DSDT, and zero table overlaps.
VM result: Exactly one signed Debug run executed. Windows halted with Stop code ACPI_BIOS_ERROR (0xA5); KiBugCheckData at GPA 0x100dbb9a0 unchanged: Arg1=0x11, Arg2=0x03, Arg3=0x00, Arg4=0x00. In the fw_cfg payload RSDP.RsdtAddress was relocated to 0x7E000500 and RSDT was valid; however EDK2 AcpiPlatformDxe/AcpiTableDxe (PcdAcpiExposedTableVersions=0x20) synthesizes its own RSDP3 for EFI_ACPI_20_TABLE_GUID with RsdtAddress=0 and skips fw_cfg RSDT/XSDT.
Next: Await instructions on firmware ACPI table exposure / EDK2 configuration.

Hypothesis: StorNVMe's CQ drain is starved by the correct-but-level-held INTx fallback; a one-vector MSI-X endpoint delivered through Hypervisor.framework's GIC message-based SPI frame removes the persistent level assertion without requiring ITS/LPI.
Patch: Reserved HVF MSI SPIs 64...79 from queried GIC resources; derive and configure an aligned MSI frame after the GICR region; append a matching MADT Generic MSI Frame and clear FADT MSI_NOT_SUPPORTED. Added PCI MSI-X at 0x90, a dedicated 4 KiB BAR2 (table +0x000, PBA +0x800), byte/word/dword table accesses, masks, PBA[0], and validated hv_gic_send_msi delivery using the guest-programmed GIC frame address and SPI data. Legacy SPI50 remains the fallback while MSI-X is disabled.
Result: Engine source type-check passes. The full Xcode build is currently blocked before Swift compilation because this Xcode installation lacks the Metal Toolchain component; no VM or Windows installation was launched.
Next: Restore/install the local Metal Toolchain or build through the existing signed Xcode Debug environment, then perform one controlled PCI-enumeration run with FLUX_VERBOSE_NVME=1 to capture MSI-X capability discovery, BAR2 assignment, table address/data, enable/mask state, and hv_gic_send_msi result before any Windows install.

Hypothesis: Holding NVMe SPI 50 asserted until guest CQ head advancement creates a GICv3 level-sensitive deadlock (Active=1, Pending=1) blocking StorNVMe IRP_MN_START_DEVICE completion; pulsing SPI 50 per completion will resolve the deadlock.
Patch: In FluxNVMe.swift, added pulseInterrupt() calling hv_gic_set_spi(spiINTID, true) followed immediately by hv_gic_set_spi(spiINTID, false) in postAdminCompletion and postIOCompletion; removed hv_gic_set_spi(..., false) from CQ head doorbell write.
Static validation: Verified pulse semantics applied to both admin and I/O completion paths; no path leaves SPI 50 asserted; build and code-signing succeeded cleanly.
VM result: Windows completed Admin Command 8 naturally (CQ0 head advanced 7 -> 8) and submitted Command 9 (Set Features Number of Queues). However, because GICD_ICFGR3 configures INTID 50 as Level-Sensitive (0x0) in hardware, deasserting the line synchronously within the MMIO handler before the guest vCPU resumes cancels the pending level interrupt before the CPU can acknowledge it. Windows timed out waiting for Command 9 completion, issued normal shutdown (CC.SHN = 01b, CSTS = 0x9), and transitioned the controller to D3hot (PMCSR = 0x3).
Next: Align interrupt handling with level-sensitive semantics (e.g. configure GIC / ACPI trigger mode as edge, or deassert level only after CPU acknowledgment / EOI rather than synchronously inside the MMIO exit).

Hypothesis: Modeling NVMe legacy INTx level-sensitive interrupt semantics with proper regINTMS/regINTMC masking and checking for unacknowledged completions (cq.head != cq.tail) across all active queues allows GICv3 and Windows stornvme.sys to acknowledge interrupts cleanly without line-hold deadlocks or lost pulses.
Patch: In FluxNVMe.swift, implemented updateInterruptState() that asserts hv_gic_set_spi(spiINTID, true) only when (regINTMS & 1) == 0 and unconsumed completions exist across any active CQ (cq.head != cq.tail), and deasserts hv_gic_set_spi(spiINTID, false) whenever masked by INTMS or all completions are drained via CQ doorbells (cq.head == cq.tail). Fixed regINTMC to clear mask bits (regINTMS &= ~val) rather than maintaining a separate register.
Static validation: Verified build and code-signing with Apple Development identity; verified INTMS/INTMC bitwise masking semantics and queue state tracking.
VM result: Windows 11 ARM64 kernel driver stornvme.sys took full ownership of the NVMe controller. Admin Commands 8 and 9 completed without timeout. Windows successfully allocated and created NVMe I/O queues (SQ1 and CQ1) with 64 entries. IRP_MN_START_DEVICE completed successfully. Over 7,000 NVMe MMIO transactions and heavy disk I/O executed across both namespaces. Windows booted completely through WinPE initialization and presented the graphical Windows 11 Setup wizard ("Select language settings") at 800x600 resolution.

Hypothesis: Backing UEFI NVRAM with a persistent file (flux-vars.fd) via MAP_SHARED ensures BootOrder and NVRAM variables survive VM restarts; injecting a minimal standard autounattend.xml into the FAT32 installer volume will automate language/locale selection and progress Windows Setup into disk partitioning.
Patch: In FluxFirmware.swift, backed varsHost with persistent flux-vars.fd mapped with MAP_SHARED and msync. In FluxUnattend.swift, generated minimal standard autounattend.xml targeting DiskID 0 (Index 3, Windows 11 Pro) without speculative bypasses. Safely backed up installer disk (flux-win11-boot.raw.bak) and injected autounattend.xml to installer volume root.
Static validation: Verified persistent vars creation and in-place byte modifications survive unmap/reopen without modifying the bundled template; verified injected autounattend.xml and installer files (boot.wim, install.swm, setup.exe) integrity.
VM result: EDK2 loaded persistent NVRAM (flux-vars.fd modified by EDK2 as proven by binary diff). Windows Setup loaded autounattend.xml from the installer volume root: the language/locale selection screen was completely skipped without manual interaction. Setup probed NSID 1 LBA 0. Setup then halted at the hardware requirements evaluation screen: "This PC doesn't currently meet Windows 11 system requirements" due to single-core processor (needs >= 2 cores), missing TPM 2.0, and disabled Secure Boot. NSID 2 write-protection actively prevented installer disk modifications.

Hypothesis: Adding temporary installation-enablement LabConfig bypasses (BypassCPUCheck=1, BypassTPMCheck=1, BypassSecureBootCheck=1) via RunSynchronous in the windowsPE pass will satisfy Windows Setup's hardware appraisal and allow unattended disk partitioning and file extraction to proceed.
Patch: In FluxUnattend.swift, added exactly three RunSynchronousCommand entries under Microsoft-Windows-Setup for HKLM\SYSTEM\Setup\LabConfig (BypassCPUCheck, BypassTPMCheck, BypassSecureBootCheck); no speculative RAM, storage, or NRO bypasses added.
Static validation: Parsed generated autounattend.xml as XML, confirmed presence of exactly three LabConfig commands and absence of extra bypasses; confirmed DiskID 0 and image Index 3; injected into flux-win11-boot.raw and verified byte-for-byte readback; verified boot.wim, install.swm, and setup.exe integrity.
Architectural Roadmap Note: These LabConfig bypasses are temporary installation-enablement measures to validate the unattended setup engine; the final Flux production architecture will replace them with native 2+ virtual CPUs, TPM 2.0, and Secure Boot.

Hypothesis: Converting the installer disk (flux-win11-boot.raw) to MBR FAT32 eliminates GPT partition collision with the target disk; fixing autounattend.xml schema errors (removing deprecated HideOEMRegistrationScreens and NetworkLocation, removing empty Password element from AutoLogon, and injecting BypassNRO and LimitBlankPasswordUse in specialize) ensures OOBE runs to completion without manual intervention.
Patch: Converted installer disk to MBR FAT32; updated FluxInstallerInjector to support Windows_FAT_32; gated bugcheck dump behind FLUX_SCAN_BUGCHECK=1 for instantaneous warm resets; corrected autounattend.xml in FluxUnattend.swift to strictly follow Windows 11 ARM64 schema.
Static validation: Disassembled and validated FAT32 partition on installer; inspected NTFS Panther logs via hdiutil read-only mount proving exact failure point was [oobeldr.exe] SMI error: "Setting is not defined in this component: /settings/OOBE/HideOEMRegistrationScreens"; verified clean build and codesign.
VM result: Automated end-to-end installation running completely unattended: Windows Setup partitioned NVMe Disk 0 (NSID 1), applied Windows 11 Pro image, configured BCD and UEFI boot entries in flux-vars.fd, survived reboot, and progressed seamlessly.

Hypothesis: In Windows 11 ARM64 (Build 26100), the setting `HideOEMRegistrationScreens` is obsolete/unsupported in Microsoft-Windows-Shell-Setup during oobeSystem, triggering SMI error 0x80220001 in oobeldr.exe. Furthermore, sandboxed Flux.app failed to inject autounattend.xml via hdiutil, leaving stale XML on the boot disk. Host-side injection of a schema-audited answer file (omitting HideOEMRegistrationScreens, removing deprecated NetworkLocation, correcting backslash escaping in specialize registry commands, and matching empty password in AutoLogon) onto a clean target disk with pristine UEFI VARS enables zero-touch progression through oobeSystem to the desktop.
Patch: In FluxUnattend.swift, fixed specialize registry path backslashes and added Password block to AutoLogon matching LocalAccounts. Built and codesigned Flux.app. Injected autounattend.xml into flux-win11-boot.raw using host tools outside sandbox. Cloned failed target disk to flux-target-disk.raw.failed_oobe; reset flux-target-disk.raw as a 64 GB clean sparse disk and reset flux-vars.fd from edk2-aarch64-vars.fd template.
Static pre-flight validation: Verified XML parses with ElementTree; confirmed absence of HideOEMRegistrationScreens and NetworkLocation; verified byte-for-byte match with mounted copy; confirmed installer critical files intact; verified target Disk 0, installer read-only Disk 1, and pristine VARS. All 9 pre-flight checks passed.
VM result: Launched clean unattended installation with auto-start. Setup automatically discovered autounattend.xml, bypassed hardware compatibility checks via LabConfig, partitioned Disk 0 (NSID 1), and is actively streaming Windows 11 Pro image installation at >20 MB/s.

Hypothesis: Concurrent Flux VMs opened the same writable NSID1 target, corrupting the NTFS image during WIM application.
Patch: Added FluxRuntimeLock, an advisory process-lifetime flock at flux-runtime.lock. FluxVM acquires it before VM creation or opening mutable runtime files, records its PID, and releases it on shutdown; kernel lock release makes crashed owners non-stale.
Result: Debug build succeeded. Archived Setup logs show Apply WIM image 3 failed at deploymentcsphelper.exe with GLE 1392 / HRESULT 0x80070570 (ERROR_FILE_CORRUPT). BootFinalize and BCDBoot did not start.
Next: Do not launch another VM until the single-owner behavior is explicitly validated with no guest boot.

Hypothesis: The target image could be destroyed by an accidental call to createDiskImage() because its creation open used O_TRUNC; separately, the production reset path needed direct backing-file identity evidence.
Patch: Changed createDiskImage() to atomic O_CREAT|O_EXCL|O_RDWR creation, refusing EEXIST without truncation, resize, or replacement. Added coarse NSID1 identity diagnostics at configure and PSCI-reset boundaries. Added an opt-in disposable reset validation mode using a UUID-named 64 MiB temporary image only.
Result: Fresh signed Debug build succeeded. The disposable image preserved inode, 64 MiB size, 96 allocated blocks, and first/middle/last 4 KiB marker checksums across 10 calls through the production platform-reset handler and FluxNVMe.reset(). No Windows target, installer, or VARS was opened.
Next: Production reset itself did not reproduce all-hole destruction. Keep the identity diagnostics for the next controlled VM run; do not change the async reset-submission race or retry installation without separate approval.

Hypothesis: A reset gate must close worker admission before drain, and READ/WRITE/WRITE ZEROES need a shared overflow-safe namespace bounds check before any host offset arithmetic.
Patch: Added a reset admission gate to FluxNVMe: reset marks resetting, waits only for already-admitted host I/O, drains queued jobs, advances generation, clears state, then remains disabled until normal CC.EN. Added common subtraction-form range validation and NVMe LBA-out-of-range status (0x0080) for READ/WRITE/WRITE ZEROES.
Result: Fresh signed Debug build succeeded. Disposable 64 MiB validation completed 100 resets with 12,800 concurrent async worker submissions: 12,707 admitted before the gate, 93 rejected after it, 0 host I/O began after reset, 0 stale completions, 0 generation mismatches, and stable sentinel checksums. First/last/exact-end valid ranges passed; out-of-range, crossing, max-NLB, and Write Zeroes crossing ranges rejected; NSID2 writes remained no-ops.
Next: Storage integrity hardening is complete. Do not start installation without explicit approval.

Hypothesis: The first PSCI SYSTEM_RESET reinitialized CPU0's GIC CPU interface without a positive guarantee that all vCPU run loops had returned from hv_vcpu_run(), allowing HVF to reject ICC_PMR_EL1 with HV_BAD_ARGUMENT.
Patch: Added a per-vCPU quiescence barrier around hv_vcpu_run(), wait for all vCPUs after hv_vcpus_exit before resetting CPU0/GIC state, and propagate reset-register API failures instead of ignoring them. Increased the existing disposable production-reset validator from 10 to 20 iterations.
Result: Signed Debug build succeeded. Preserved installed Windows boot reached desktop without a GIC reset failure. Isolated production reset validation passed 20/20 with every ICC_PMR_EL1 and PPI27 initialization succeeding; the disposable disk inode, size, allocation, and marker hashes remained unchanged.
Next: The first-reset CPU0/GIC ordering fault is addressed; resume installed-Windows boot validation without altering storage, PCI, ACPI, MSI-X, or INTx behavior.

Hypothesis: EDK2's next xHCI requirement is controller operational/runtime-register programming, and the existing synchronous HCRST completion can violate its polling assumptions.
Patch: Added narrow xHCI bring-up traces and state capture for operational registers, interrupter 0, and Doorbell 0. HCRST now exposes HCRST/CNR during a bounded reset interval before returning HCHalted with CNR clear. No command execution, event posting, interrupt delivery, port device, or HID behavior was added.
Result: Fresh signed Debug build passed. The one clean EDK2 run completed HCRST, CONFIG=8, DCBAAP=0xFFFE8000, CRCR=0xFFFE8080/RCS=1, ERSTSZ=1, ERSTBA=0xFFFEB080, ERDP=0xFFFE9080, IMAN.IE=1, and Run/Stop=1. It then stopped the controller without ringing Doorbell 0; no command TRB, completion event, or interrupt was generated.
Next: The controller infrastructure is configured. The first missing requirement is a standards-correct root-port connection/change-event path; do not invent a command or completion before that path is deliberately implemented.

Hypothesis: EDK2 does not submit xHCI commands because both advertised USB2 root ports report disconnected.
Patch: Added two permanently connected USB2 high-speed PORTSC instances (CCS/CSC, bounded PR->PED/PRC transition, W1C change bits), one event-ring segment producer, and an xHCI-owned BAR2 one-vector MSI-X capability/table/PBA path using FluxGIC's existing message-frame validation and delivery. Added the xHCI guest-RAM binding required to inspect ERST and post event TRBs.
Result: Fresh signed Debug build passed. EDK2 configured the existing command/event infrastructure, received Port Status Change Events for ports 1 and 2 at ERST 0xFFFE9080 indices 0/1 (cycle 1), cleared CSC, reset both ports, and observed CCS=1/PED=1/PR=0/PRC=1. It then rang Doorbell 0 and timed out its Enable Slot command because command-ring fetch/command completion is intentionally unimplemented. xHCI MSI-X BAR2 was assigned 0x10012000, but EDK2 did not read/enable MSI-X or program its table, so no message interrupt was attempted.
Next: Implement only command-ring fetch plus the observed Enable Slot command and its Command Completion Event; do not add HID descriptors or any additional command type first.

Hypothesis: After Enable Slot, EDK2 needs only standards-correct Address Device command validation and a Command Completion Event before it can advance the first root-port enumeration.
Patch: Added command-ring handling for only Address Device (TRB type 11), requiring Slot 1 enabled, aligned in-RAM input context, and a nonzero Slot 1 DCBAA device-context entry. It posts the normal success Command Completion Event and records addressed state; it does not inspect endpoint contexts or service transfers.
Result: Fresh signed Debug build passed. EDK2 consumed the Enable Slot completion at 0xFFFE9080 index 2 and the Address Device completion at index 3, both cycle 1. It then reset Port 2 and submitted a second Enable Slot at command TRB 0xFFFE80A0. Flux correctly left that command unconsumed because this focused milestone has only Slot 1; no endpoint, HID, or MSI-X behavior was added.
Next: If continuing USB enumeration, implement a bounded two-slot allocator for the two already advertised root ports before considering endpoint configuration or HID.

Hypothesis: EDK2 can enumerate the two connected root ports when Enable Slot and Address Device retain independent per-slot state and derive each slot's root-port association from its Address Device input context.
Patch: Replaced the one-slot xHCI state with a two-entry slot table, advertised MaxSlots=2 in HCSPARAMS1, allocated the first free slot for Enable Slot, and validated/recorded Root Hub Port Number for Address Device.
Result: Fresh signed Debug validation consumed Enable Slot and Address Device for Slot 1 / Port 1 and Slot 2 / Port 2. Slot 2 Enable Slot TRB at 0xFFFE8060 posted Success at event index 4; Slot 2 Address Device used input context 0xFFFEC8C0 and posted Success at index 5. EDK2 consumed both events and advanced ERDP to 0xFFFE90A8. No HID, endpoint, transfer, or MSI-X behavior was added.
Next: No further xHCI command or transfer was observed: EDK2 stopped the controller after the second Address Device completion. Investigate that concrete stop condition before adding another xHCI feature.

Hypothesis: The installed Windows xHCI stack will expose the first post-firmware requirement through its controller reset or first command/endpoint doorbell without requiring HID or transfer emulation.
Patch: Added opt-in `FLUX_TRACE_XHCI_HANDOFF` observability for selected xHCI PCI handoff reads, PORTSC reads, and non-zero endpoint doorbells only. No controller, command-ring, port, MSI-X, or transfer behavior changed.
Result: Fresh signed Debug run booted the preserved target. After firmware's completed two-slot enumeration, Windows rediscovered the xHCI function, assigned BAR0=0x3EEF0000 and BAR2=0x3EEEF000, set PCI Command=0x416, and repeatedly issued HCRST (USBCMD=0x2); each reset completed with HCRST/CNR clear and HCHalted set. Windows did not program CRCR, DCBAAP, CONFIG, ERST, ERDP, or IMAN after its resets, and no Doorbell 0 or non-zero endpoint doorbell/TRB followed. MSI-X capability was read but not enabled/programmed.
Next: The first Windows-specific boundary is repeated controller reset followed by no operational-register setup. Investigate why Windows rejects or tears down the controller immediately after a successful HCRST before adding any command, endpoint, or HID implementation.

Hypothesis: A one-shot, non-invasive capture of the first Windows post-HCRST read sequence can distinguish a malformed xHCI structural field from a correct controller that Windows abandons for another reason.
Patch: Added a read-only audit that arms on the observed PCI Command 0x0416, captures distinct capability/operational/PCI reads through the next HCRST, then disables itself. No xHCI device semantics changed.
Result: Windows HCRST completed with USBCMD=0, USBSTS=1 (HCHalted only; no HSE/HCE/CNR). It read valid xHCI values: CAPLENGTH/HCIVERSION=0x01100040, HCSPARAMS1=0x02000102 (2 slots, 1 interrupter, 2 ports), HCSPARAMS2/3=0, HCCPARAMS1=0x00400000 (32-byte contexts, xECP 0x40), PAGESIZE=1, DBOFF=0x1000, RTSOFF=0x2000, and Supported Protocol DW0=0x02000002. The first concrete mismatch is PCI configuration: its combined Command/Status read was 0x00000416, proving PCI Status=0 even though CapPtr=0x50 and an MSI-X capability are exposed. The PCI Capabilities List status bit (0x0010) is clear.
Next: Pending approval, make the smallest PCI Type-0 correction: expose PCI Status.Capabilities List=1 for xHCI. Do not change xHCI command, port, MSI-X, or HID behavior in that patch.

Hypothesis: Windows abandons xHCI because PCI Status.Capabilities List is clear despite the exposed MSI-X capability chain.
Patch: Set only xHCI Type-0 PCI Status bit 4 (Capabilities List), yielding Status=0x0010 while leaving the independently writable Command register and all capability/BAR state unchanged.
Result: Fresh signed Debug target boot proved the correction: Windows enabled xHCI MSI-X (message 0x0A0A0040/data 65), completed HCRST, configured ERSTSZ=1, ERSTBA=0xFFFDE000, ERDP=0xFFFDD008, CONFIG=2, DCBAAP=0xFFFDC000, CRCR=0xFFFDE201/RCS=1, IMAN.IE=1, and Run/Stop=1. It posted and consumed port-change events. The prior abandonment before operational setup is gone; no Doorbell 0/TRB appeared in this bounded run.
Next: Stop here. The next task must isolate the first post-Windows-initialization command or port-enumeration requirement; do not add HID or command behavior without fresh evidence.

Hypothesis: With the corrected PCI capability metadata, a longer installed-Windows run will reveal the first post-initialization xHCI command or endpoint transfer without changing controller behavior.
Patch: None (observation only).
Result: A fresh signed Debug run completed the full 15-minute active window. Windows kept xHCI running after HCRST and setup (CRCR, DCBAAP, CONFIG, ERST/ERDP, IMAN), with MSI-X enabled at 0x0A0A0040/data 65 and two successful observed sends. It consumed the two initial Port Status Change Events (ERDP advanced) and cleared CSC/PRC on both ports; both later read as PORTSC=0x00000C01 (connected, high-speed). Windows issued no Doorbell 0, no non-zero endpoint doorbell, no command TRB, and no transfer TRB; it also did not stop the controller.
Next: No implementation is justified from this run. Collect focused evidence for why Windows clears the root-port changes but does not initiate port reset/enumeration, before adding command or transfer support.

Hypothesis: Windows is acknowledging valid Port Status Change Event TRBs but declines root-port enumeration because a required root-hub change indication is missing or inconsistent.
Patch: Added opt-in `FLUX_TRACE_XHCI_PORT_AUDIT` telemetry only; no xHCI state semantics changed. The temporary scheme environment entry was removed after the run.
Result: Static and current-run evidence agree. Both ports reset to and are first read as 0x00020C01 (CCS=1, high-speed ID 3, CSC=1); Windows consumes the two Port Status Change Events (parameter 0x01000000/0x02000000, status 0, control 0x00008801), advances ERDP by 0x20, writes 0x200 to clear CSC and 0x20000 to clear PRC, and reaches 0x00000C01. It never writes PR. Crucially, USBSTS reads as 0 after the port events, and source confirms `postPortEvent` sets IMAN.IP but never USBSTS.PCD. HCCPARAMS1.PPC=0 and PP=0 are mutually consistent; Supported Protocol is USB2 ports 1-2 with default USB2 speed mapping, consistent with PortSpeed=3.
Next: Pending approval, the smallest standards-correct fix is to set USBSTS.PCD when a Port Status Change Event is posted and retain it until the existing USBSTS W1C path clears bit 4. Do not change port power, link, command, transfer, HID, or MSI-X behavior in that patch.

Hypothesis: Windows root-port enumeration requires USBSTS.PCD to be asserted whenever a Port Status Change Event is pending.
Patch: Set USBSTS.PCD (bit 4) in `postPortEvent()` at the same point as event/IMAN pending state. Existing USBSTS W1C handling is unchanged.
Result: Fresh signed Debug target boot showed Windows read USBSTS=0x00000010 after controller Run and both port events, proving PCD was exposed. Windows then advanced ERDP and cleared CSC/PRC on both ports, but did not write PR, ring Doorbell 0, or issue a command/transfer TRB. No Windows USBSTS W1C write was observed in this window.
Next: Stop. PCD is now correct but insufficient for root-port enumeration; perform a new evidence-only audit before any further xHCI change.

Hypothesis: Windows declines root-port reset because Flux reports U0 for a connected USB2 port before it is enabled.
Patch: Changed only the disabled connected port's PORTSC PLS from U0 (0) to Polling (7); enabled ports remain U0 and the existing reset/PRC flow is unchanged.
Result: Intel xHCI specifies Polling after USB2 attach until software reset. Static states are pre-reset 0x00020CE1, reset-in-progress 0x00020CF1, and post-reset after CSC clear 0x00200C03. Fresh signed Debug target boot returned 0x00020CE1 before CSC W1C and 0x00000CE1 afterward, but Windows still did not write PR, Doorbell 0, or a command TRB.
Next: Stop. The pre-reset PLS correction is valid but insufficient; do not change another field without a new evidence-only hypothesis.

Hypothesis: Windows declines root-port reset because Flux exposes USB2 High Speed before the port has completed reset/speed negotiation.
Patch: Removed the unconditional High-Speed PortSpeed encoding. Disabled/being-reset ports now report PortSpeed=0 (Undefined); enabled ports report Full Speed (1). PLS and all other xHCI behavior are unchanged.
Result: Fresh signed Debug target boot returned PORTSC=0x000200E1 before CSC W1C and 0x000000E1 afterward (CCS=1, PED=0, PR=0, PLS=Polling, PortSpeed=0). Windows still did not write PR, Doorbell 0, or a command TRB.
Next: Stop. The PortSpeed state correction is valid but insufficient; do not change another field without a new evidence-only hypothesis.

Hypothesis: Windows needs to observe a real Port 1 CCS 0->1 edge after its xHCI event/command/MSI-X infrastructure is ready before it will reset the USB2 port.
Patch: Made reset state physically disconnected for both ports. During the Windows-owned controller run only, attach Port 1 once after ERST/ERDP/DCBAAP/CRCR/IMAN/MSI-X are configured; Port 2 remains disconnected. The attach raises CSC, PCD, one Port Status Change Event, and the existing MSI-X delivery.
Result: Fresh signed Debug target boot read disconnected PORTSC1/2=0x80 after HCRST. After Run, Port 1 transitioned CCS=0->1 and Windows read 0x000200E1, consumed the single event (ERDP +0x10), read USBSTS=0x10, then cleared CSC and read 0x000000E1. It did not write PR, Doorbell 0, or a command TRB.
Next: Stop. A real fresh connect edge is insufficient; do not change another xHCI field without a new evidence-only hypothesis.

Hypothesis: With HCCPARAMS1.PPC=0, Flux must expose PORTSC.PP=1 because the root port is hard-wired powered; PP=0 makes an otherwise connected port nonfunctional.
Patch: Set PORTSC.PP (bit 9) in both disconnected and connected port readback. PP remains read-only/hard-wired because PPC=0; no other port state or write semantics changed.
Result: Fresh signed Debug target boot read disconnected PORTSC1/2=0x00000280. After the real Port 1 attach it read 0x000202E1; Windows wrote PP=1 (0x00000200) and PP remained asserted. After CSC W1C, readback was 0x000002E1. Windows then wrote PR=1 (0x00000210), observed reset in progress (0x000002F1), then reset completion (0x00200603: CCS, PED, PP, U0, Full Speed, PRC). It rang Doorbell 0, successfully enabled and addressed Slot 1, then issued unsupported Command TRB type 10 at 0xFFFF6220. Stopped at that first new requirement.
Next: The PP correction is validated and materially advances Windows xHCI enumeration. Do not alter root-port semantics further; the next scoped task should assess only Command TRB type 10 (Disable Slot) handling if approved.

Hypothesis: Windows issues Disable Slot because Flux returns Address Device success without constructing the required output Device Context.
Patch: Added opt-in, read-only `FLUX_TRACE_XHCI_ADDRESS_AUDIT` context telemetry. It is disabled by default and emits Input/Output Slot and EP0 contexts around Address Device without modifying guest memory or controller behavior.
Result: Static audit proves the present implementation only validates the input pointer/root-port field, posts a success completion, and records host-local `addressed/port` fields. It performs no output-context stores, assigns no USB address, and programs neither the output Slot Context nor EP0 Context. Existing trace shows no Slot 1 endpoint doorbell between the Address Device completion and Disable Slot; completion was valid (code 1, Slot 1, cycle 1, MSI-X return 0).
Next: Do not implement Disable Slot. The smallest standards-correct next implementation, if approved, is Address Device output-context population from the validated Input Context before returning Success.

Hypothesis: Windows accepts the BSR=1 Address Device command only when DCBAA[Slot] points to an Output Device Context containing the input Slot/EP0 configuration plus controller-owned Default/Running states.
Patch: For CSZ=0, validate Input Control Add flags for Slot and EP0, copy eight DWORDs each from the Input Slot and EP0 contexts to the Output Device Context at DCBAA[Slot], force Output Slot state=Default/address=0, and force Output EP0 state=Running. The command is not consumed if the output context cannot be prepared; completion remains after the writes. Added bounded raw-context telemetry during the existing Windows audit.
Result: Fresh signed Debug build passed. The single installed-Windows validation reached controller Run and Port 1 enumeration, but repeatedly issued PORTSC PR writes after each observed reset completion (PORTSC alternated through 0x000002F1 and 0x00200603). It never rang Doorbell 0, so Address Device and the new output-context stores were not reached in this run. No xHCI behavior was changed after that concrete earlier boundary.
Next: Stop. Audit the repeated post-reset PORTSC PR path before attempting another Address Device validation; do not implement Disable Slot or transfers.

Hypothesis: Windows repeats Port 1 reset because the reset-completion PRC notification is delivered after, rather than with, the completion state.
Patch: None (evidence-only audit).
Result: Three consecutive cycles show Windows reads PORTSC=0x000002E1 before PR, writes 0x00000210, and reads 0x000002F1 (CCS=1, PED=0, PR=1, Polling, PP=1, speed=0). Flux then completes reset to 0x00200603 (CCS=1, PED=1, PR=0, U0, PP=1, Full Speed, PRC=1), which Windows reads. It immediately writes PR again before the reset-completion event is posted. Source explains the ordering: `advance()` sets PRC/eventQueued=false during a read, but `postPortEventsLocked()` is called only after MMIO writes. The event is therefore posted by the next PR write, already belonging to the following reset. PR is observable; PED/PLS/speed remain stable until that next legitimate PR write; no duplicate completion event is posted. The defect is delayed PRC Port Status Change Event delivery, not reset duration or output-context handling.
Next: Pending approval, post and deliver the reset-completion Port Status Change Event as part of the completion transition, before returning PORTSC with PRC=1 to the guest. Do not change Address Device, Disable Slot, or transfer behavior.

Hypothesis: Windows repeats Port 1 reset because the reset-completion Port Status Change Event/MSI-X notification is queued only after a later unrelated MMIO write.
Patch: `advance()` now posts the single reset-completion Port Status Change Event, sets its normal PCD/IMAN.IP state, and prepares MSI-X immediately after setting PRC/PED and before `readMMIO` returns PORTSC. MSI delivery occurs after releasing the xHCI lock. The existing `eventQueued` guard prevents reposting on later reads.
Result: Fresh signed Debug build launched successfully. Runtime validation could not reach Windows xHCI ownership: the preserved target booted directly into Windows Automatic Repair (“Your device ran into a problem and couldn't be repaired”, SrtTrail.txt) before the target Windows xHCI path. The run was stopped without disk/VARS/code changes beyond this patch.
Next: Preserve this patch. Repair or replace the preserved installed-Windows target only with explicit approval, then repeat one target-boot ordering validation; do not make another xHCI change first.

Hypothesis: Automatic Repair is caused by an invalid/missing boot chain, destructive target-image recreation, filesystem damage, or repeated interrupted guest boots.
Patch: None (evidence-only, read-only attachment).
Result: Target is intact at `.../Containers/com.flux.Flux/Data/Library/Application Support/Flux/flux-target-disk.raw`: inode 9095541, 64 GiB, 29,001,216 allocated 512-byte blocks, and nonzero independent hashes at LBA0, ESP, middle, and near-end regions. GPT has EFI/MSR/Windows/Recovery partitions. The FAT32 ESP contains `EFI/Boot/bootaa64.efi`, `EFI/Microsoft/Boot/bootmgfw.efi`, and both Boot/Recovery BCD stores. VARS contains active Boot0004 `Windows Boot Manager` targeting `\EFI\Microsoft\Boot\bootmgfw.efi`; BootOrder is 0004,0001,0002,0003. `setupact.log` records `OOBEBoot` completed successfully at 2026-09-23 01:13:05. No SrtTrail.txt is present on the mounted Windows volume; macOS cannot mount the NTFS WinRE partition, and a read-only strings scan produced no SrtTrail root-cause text. The visible recovery message is therefore not yet tied to a filesystem, BCD, driver, or NVMe fault. Existing logs do show repeated intentionally stopped xHCI target-boot experiments after the last desktop-capable state.
Next: Do not repair yet. The smallest safe recovery action, pending approval, is one Windows Recovery Environment boot with no device-model changes and extraction of SrtTrail.txt / boot-status diagnostics before any repair command.

Hypothesis: A single WinRE boot can expose the actual recovery trigger through SrtTrail.txt and read-only BCD/boot-status inspection.
Patch: None (evidence-only).
Result: The preserved target reached WinRE's Automatic Repair screen and explicitly identified `C:\WINDOWS\System32\Logfiles\Srt\SrtTrail.txt`; it reported only “Your device ran into a problem and couldn't be repaired” and “Couldn't connect to the network.” Flux has no host-to-guest keyboard or pointer input implementation (`FluxDisplayView` has no NSEvent handlers and xHCI has no HID/transfer path), so both a host click and Enter left the guest screen unchanged. Consequently WinRE Command Prompt, volume letters, `bcdedit /enum all`, the SrtTrail contents, and Continue availability cannot be accessed without an out-of-scope input implementation. No repair command, disk/VARS change, or xHCI change was made.
Next: Do not infer a driver, filesystem, or BCD fault. With explicit approval, implement a minimal temporary guest input path or another read-only offline NTFS reader solely to obtain SrtTrail and boot-status data; do not repair Windows first.

Hypothesis: The existing PL011 UART can serve as an isolated temporary host-input route for WinRE diagnostics without altering the in-progress xHCI model.
Patch: Added a bounded PL011 RX FIFO and focused AppKit key forwarding in `FluxDisplayView`; this is explicitly serial-console-only and does not alter xHCI, PCI, ACPI, storage, MSI-X, or guest state.
Result: The signed Debug build launched. The target progressed through Boot0004 / Windows Boot Manager, but WinRE is graphical and does not consume the PL011 serial-console stream. The available desktop-control layer also became unresponsive during this boot, so no host key event could be observed in the RX FIFO. More fundamentally, a UART console cannot navigate the WinRE GUI or invoke its Command Prompt.
Next: Stop this diagnostic path. Under the present constraints there is no viable guest-visible keyboard: the only standards-compatible existing input bus is the unfinished xHCI path. To collect SrtTrail/BCD diagnostics, approve either a narrowly scoped xHCI HID control-transfer path or a read-only offline NTFS extraction route.

Hypothesis: An offline read-only extraction of SrtTrail and the ESP BCD can distinguish a real boot/storage fault from recovery escalation.
Patch: None. The target was attached with `hdiutil` in read-only raw-disk mode; `SrtTrail.txt` and BCD were copied only to `/private/tmp/flux-winre-readonly/` and parsed there.
Result: SrtTrail reports `Number of root causes = 0`. Main OS, disk, disk metadata, target OS, volume content, Boot Manager, boot log, registry hives, and bugcheck checks all completed with `0x0`; only cloud-network startup returned `0x4c6`. The BCD identifies Windows 11 and Windows Recovery Environment, has `recoveryenabled=1` and recoverysequence `{578dc5ac-b6ee-11f1-8111-dbd76d91c191}`, with no explicit `bootstatuspolicy` or display-message override element. The offline Windows volume contains `winload.efi` and SYSTEM hive; SrtTrail is on the main Windows NTFS partition. This supports recovery escalation/failure-count state, not a specific file, driver, filesystem, or storage defect.
Next: Do not repair automatically. The smallest safe next action is a controlled one-time normal boot/Continue-to-Windows attempt once guest GUI input is available, rather than Startup Repair, BCD edits, or storage changes.

Hypothesis: WinRE is entered solely due to recovery escalation and one temporary `recoveryenabled=0` policy change will allow the intact target to boot normally.
Patch: Backed up EFI `BCD` to `artifacts/recovery-bypass/BCD.original` (28,672 bytes, SHA-256 `e975b8e111651b6ad9f494bfc92ea4ce537969655bae99e848d6a759b1f75395`). Changed exactly the Windows 11 loader's inline BCD element `16000009` (`recoveryenabled`) from `01` to `00` for one controlled signed Debug boot, then restored that byte to `01` after the test. No boot device/path/order/VARS field changed.
Result: Boot0004 -> Windows Boot Manager bypassed WinRE, reached FluxUser, and reached the Windows desktop. Existing Windows xHCI behavior advanced through Port 1 reset, Doorbell 0, Enable Slot, and Address Device with populated output Slot/EP0 contexts. The first new unsupported command is TRB type 15 at `0xffff6220`; it is not Disable Slot. The BCD recovery byte is restored to `01`. Its full post-test hash differs because Windows updated normal BCD boot-state data during the successful boot; the backup remains preserved and only the temporary field was restored.
Next: Do not run repair. The recovery escalation diagnosis is confirmed. The next xHCI task, if approved, must investigate only command TRB type 15 after Address Device; do not treat it as Disable Slot.

Hypothesis: Windows may submit an EP0 transfer between Address Device completion and Stop Endpoint.
Patch: Enabled a bounded, read-only `FLUX_TRACE_EP0_STOP` trace; fixed only its 64-bit raw-value formatter after the first diagnostic pass crashed while printing a valid Setup Stage.
Result: Windows rang Slot 1 / Target 1, then submitted Setup (GET_DESCRIPTOR Device, 64 bytes) -> IN Data (64 bytes) -> Status OUT on EP0 before ringing Doorbell 0 for Stop Endpoint. EP0 stayed Running/Control, MPS=64, CErr=3, TRDP unchanged, DCS=1. Stop Endpoint was then Type 15, Slot 1, EP 1, Suspend=0. No controller behavior changed; the scheme trace flag is now disabled.
Next: The first implementation candidate is the real EP0 control-transfer execution/completion path for the observed Device Descriptor request. Do not implement without approval.
Hypothesis: Windows times out because Slot 1 EP0 GET_DESCRIPTOR(Device) is submitted but never serviced.
Patch: Added only the exact observed Setup/Data-IN/Status-OUT Device Descriptor transaction, bounded guest-buffer validation, EP0 dequeue advance, and one Transfer Event/MSI-X notification. Unsupported chains/requests remain unconsumed.
Result: Fresh Debug build passed. On the preserved target, Windows rang Slot 1 EP0 and submitted the exact Device Descriptor chain at 0xffff5400. Flux returned 18 bytes to 0xffff5600, advanced TRDP to 0xffff5450, posted a Success Transfer Event with residual 46 at ERST index 6, and delivered MSI-X (0xa0a0040/data 65, return 0). Windows advanced ERDP to 0xffff3078, proving it consumed the event, then immediately rang Doorbell 0 for command TRB type 10 (Disable Slot) at 0xffff5220. The controlled run stopped there.
Next: Do not implement Disable Slot without a separate evidence-led approval.

Hypothesis: Windows rejected the completed Device Descriptor request because Flux used one final Event Data completion with a residual rather than separate Data-TD and Status-TD completions.
Patch: Changed only the observed Slot 1 EP0 GET_DESCRIPTOR(Device) completion sequence: Data Event Data now posts Short Packet (13) with 18 actual bytes, then Status Event Data posts Success (1) with zero bytes. The EP0 dequeue advances 0xfffde400 -> 0xfffde430 -> 0xfffde450 with DCS preserved; existing MSI-X coalescing delivers the queued pair with one successful message.
Result: Fresh signed Debug run passed the requested boundary. Windows consumed both events (ERDP advanced to 0xfffdd088), did not issue Disable Slot, and next rang Doorbell 0 for the first new unsupported command: TRB type 13 at 0xfffde220 (parameter 0xfffd9000, control 0x1003401). MSI-X delivery to 0xa0a0040/data 65 returned 0.
Next: Stop here. Do not implement command type 13 without a separate evidence-only audit and approval.

Hypothesis: After EP0 Device Descriptor completion, Windows sends Configure Endpoint (TRB type 13) to update EP0 Max Packet Size to 64 and advance the transfer dequeue pointer, after which enumeration will proceed to port reset and Address Device (BSR=0).
Patch: Implemented minimal Configure Endpoint (TRB type 13) handling in FluxXHCI.swift: decoded Input Control Context, honored Drop/Add flags, captured pre-copy Slot Context DW3 to preserve controller-owned Slot State and USB Address, transitioned added EP0 to Running (state 1), preserved TRDP (0xfffec450) and DCS (1), updated Output Device Context in DCBAA[Slot 1], posted Success Command Completion Event at ERST index 8, and delivered MSI-X.
Result: Windows consumed the Configure Endpoint Command Completion Event (ERDP advanced to 0xfffeb098), issued Port 1 reset (PORTSC PR=1), consumed the reset completion Port Status Change Event (ERDP advanced to 0xfffeb0a8), and next submitted the first new unsupported command: TRB type 11 (Address Device with BSR=0) at GPA 0xfffec230, Parameter 0xfffdf000, Control 0x01002c01. Stopped at this boundary.
Next: Implement only the observed Address Device (BSR=0) command to assign the guest USB address without speculative transfer handling.

Hypothesis: The later BSR=0 Address Device command must distinguish an already initialized Default-state context from an Addressed slot, then allocate one unique USB address.
Patch: Added `Slot.defaultContextReady` to keep BSR=1's Default-state setup separate from `addressed`. The BSR=0 path validates that Default context, allocates the first unused address in 1...127, writes it and Slot State=Addressed to the Output Slot Context, retains it in host slot state, then posts the existing Success Command Completion/MSI-X notification.
Result: Fresh Debug build passed. In one preserved-target run, Windows completed BSR=1 Address Device and Configure Endpoint, then reset Port 1 again. Its first next command was instead Disable Slot (TRB type 10, Slot 1) at 0xfffde230, control 0x01002801. No BSR=0 Address Device was issued, so the new path was not invoked or runtime-validated.
Next: Stop per the one-command milestone boundary. Audit the Type 10 Disable Slot decision before changing additional xHCI behavior.

Hypothesis: The BSR=0 address-allocation patch regressed the earlier BSR=1/Configure Endpoint state and caused Windows to issue Disable Slot instead of BSR=0 Address Device.
Patch: None (regression audit only).
Result: Static review finds no guest-visible BSR=1 change: BSR=1 still produces Slot State=Default/address=0 and EP0=Running, while host state is enabled=true, defaultContextReady=true, addressed=false, usbAddress=0, port=1. GET_DESCRIPTOR and Configure Endpoint retain their previously recorded successful Data/Status events and EP0 transition. The second port reset touches only Port fields (enabled/resetDeadline/changes/eventQueued); it does not mutate `slots`, DCBAA, or Output Slot/EP0 Context. The BSR=0 allocation branch was never executed before the Type 10 divergence. No paired last-good/current trace captures an earlier semantic difference, so no regression is proven. Disable Slot is legal xHCI re-enumeration cleanup after a port reset but its reason cannot be inferred from this evidence.
Next: Do not patch. Capture a paired, bounded trace of the Windows reason for the second reset/Disable Slot only if a further evidence-only run is approved.
