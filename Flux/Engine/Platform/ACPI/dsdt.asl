DefinitionBlock ("dsdt.aml", "DSDT", 2, "FLUX", "FLUXVM", 1)
{
    Scope (_SB)
    {
        Device (CPU0)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 0)
        }

        Device (CPU1)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 1)
        }

        Device (CPU2)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 2)
        }

        Device (CPU3)
        {
            Name (_HID, "ACPI0007")
            Name (_UID, 3)
        }

        Device (COM0)
        {
            Name (_HID, "ARMH0011")
            Name (_UID, 0)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x09000000, 0x00001000)
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive)
                {
                    33
                }
            })
        }

        Device (VR00)
        {
            Name (_HID, "LNRO0005")
            Name (_UID, 0)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0A000000, 0x00000200)
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive)
                {
                    48
                }
            })
        }

        Device (VR01)
        {
            Name (_HID, "LNRO0005")
            Name (_UID, 1)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0A000200, 0x00000200)
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive)
                {
                    49
                }
            })
        }

        Device (PCI0)
        {
            Name (_HID, "PNP0A08")
            Name (_CID, "PNP0A03")
            Name (_SEG, 0x00)
            Name (_BBN, 0x00)
            Name (_UID, 0x00)
            Name (_CCA, 0x01)

            Name (_CRS, ResourceTemplate ()
            {
                WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                    0x0000, 0x0000, 0x000F, 0x0000, 0x0010)
                DWordIO (ResourceProducer, MinFixed, MaxFixed, PosDecode, EntireRange,
                    0x00000000, 0x00000000, 0x0000FFFF, 0x3EFF0000, 0x00010000)
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
                    0x00000000, 0x10000000, 0x3EEFFFFF, 0x00000000, 0x2EF00000)
            })

            Name (_PRT, Package ()
            {
                // Device 1, Pin 0 (INTA), Source 0, GSI 50
                Package () { 0x0001FFFF, 0x00, 0x00, 50 }
            })

            Method (_OSC, 4, NotSerialized)
            {
                CreateDWordField (Arg3, 0x00, CDW1)
                CreateDWordField (Arg3, 0x04, CDW2)
                CreateDWordField (Arg3, 0x08, CDW3)

                // Flux does not implement native PCIe hot-plug, PME, AER, or
                // PCIe capability-structure ownership.  Do not return the OS
                // request unchanged: that incorrectly grants every requested
                // control.  For non-query requests, report that controls were
                // masked; CDW3 returns the granted (empty) control set.
                If (LNotEqual (And (CDW1, One), One))
                {
                    If (LNotEqual (CDW3, Zero))
                    {
                        Or (CDW1, 0x10, CDW1)
                    }
                }
                Store (Zero, CDW3)
                Return (Arg3)
            }
        }
    }
}
