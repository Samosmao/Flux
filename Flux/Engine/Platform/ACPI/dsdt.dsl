/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of Flux/Engine/Platform/ACPI/dsdt.aml
 *
 * Original Table Header:
 *     Signature        "DSDT"
 *     Length           0x000001E2 (482)
 *     Revision         0x02
 *     Checksum         0xCE
 *     OEM ID           "FLUX"
 *     OEM Table ID     "FLUXVM"
 *     OEM Revision     0x00000001 (1)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "DSDT", 2, "FLUX", "FLUXVM", 0x00000001)
{
    Scope (_SB)
    {
        Device (CPU0)
        {
            Name (_HID, "ACPI0007" /* Processor Device */)  // _HID: Hardware ID
            Name (_UID, Zero)  // _UID: Unique ID
        }

        Device (COM0)
        {
            Name (_HID, "ARMH0011")  // _HID: Hardware ID
            Name (_UID, Zero)  // _UID: Unique ID
            Name (_CRS, Buffer (0x17)  // _CRS: Current Resource Settings
            {
                /* 0000 */  0x86, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x09,  // ........
                /* 0008 */  0x00, 0x10, 0x00, 0x00, 0x89, 0x06, 0x00, 0x01,  // ........
                /* 0010 */  0x01, 0x21, 0x00, 0x00, 0x00, 0x79, 0x00         // .!...y.
            })
        }

        Device (VR00)
        {
            Name (_HID, "LNRO0005")  // _HID: Hardware ID
            Name (_UID, Zero)  // _UID: Unique ID
            Name (_CRS, Buffer (0x17)  // _CRS: Current Resource Settings
            {
                /* 0000 */  0x86, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0A,  // ........
                /* 0008 */  0x00, 0x02, 0x00, 0x00, 0x89, 0x06, 0x00, 0x01,  // ........
                /* 0010 */  0x01, 0x30, 0x00, 0x00, 0x00, 0x79, 0x00         // .0...y.
            })
        }

        Device (VR01)
        {
            Name (_HID, "LNRO0005")  // _HID: Hardware ID
            Name (_UID, One)  // _UID: Unique ID
            Name (_CRS, Buffer (0x17)  // _CRS: Current Resource Settings
            {
                /* 0000 */  0x86, 0x09, 0x00, 0x01, 0x00, 0x02, 0x00, 0x0A,  // ........
                /* 0008 */  0x00, 0x02, 0x00, 0x00, 0x89, 0x06, 0x00, 0x01,  // ........
                /* 0010 */  0x01, 0x31, 0x00, 0x00, 0x00, 0x79, 0x00         // .1...y.
            })
        }

        Device (PCI0)
        {
            Name (_HID, "PNP0A08" /* PCI Express Bus */)  // _HID: Hardware ID
            Name (_CID, "PNP0A03" /* PCI Bus */)  // _CID: Compatible ID
            Name (_SEG, Zero)  // _SEG: PCI Segment
            Name (_BBN, Zero)  // _BBN: BIOS Bus Number
            Name (_UID, Zero)  // _UID: Unique ID
            Name (_CCA, One)  // _CCA: Cache Coherency Attribute
            Name (_CRS, Buffer (0x46)  // _CRS: Current Resource Settings
            {
                /* 0000 */  0x88, 0x0D, 0x00, 0x02, 0x0C, 0x00, 0x00, 0x00,  // ........
                /* 0008 */  0x00, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x10, 0x00,  // ........
                /* 0010 */  0x87, 0x17, 0x00, 0x01, 0x0C, 0x03, 0x00, 0x00,  // ........
                /* 0018 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,  // ........
                /* 0020 */  0x00, 0x00, 0x00, 0x00, 0xFF, 0x3E, 0x00, 0x00,  // .....>..
                /* 0028 */  0x01, 0x00, 0x87, 0x17, 0x00, 0x00, 0x0C, 0x01,  // ........
                /* 0030 */  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,  // ........
                /* 0038 */  0xFF, 0xFF, 0xEF, 0x3E, 0x00, 0x00, 0x00, 0x00,  // ...>....
                /* 0040 */  0x00, 0x00, 0xF0, 0x2E, 0x79, 0x00               // ....y.
            })
            Name (_PRT, Package (0x01)  // _PRT: PCI Routing Table
            {
                Package (0x04)
                {
                    0x0001FFFF, 
                    Zero, 
                    Zero, 
                    0x32
                }
            })
            Method (_OSC, 4, NotSerialized)  // _OSC: Operating System Capabilities
            {
                CreateDWordField (Arg3, Zero, CDW1)
                CreateDWordField (Arg3, 0x04, CDW2)
                CreateDWordField (Arg3, 0x08, CDW3)
                If (((CDW1 & One) != One))
                {
                    If ((CDW3 != Zero))
                    {
                        CDW1 |= 0x10
                    }
                }

                CDW3 = Zero
                Return (Arg3)
            }
        }
    }
}

