import Foundation

nonisolated final class FluxEngine: Sendable {

    func testHypervisor(edition: String = "Windows 11 Pro") {
        let vm = FluxVM()
        vm.runTest(edition: edition)
    }

    func runResetDiskValidation() -> Bool {
        FluxVM().runResetDiskValidation()
    }

    func validateNVMe() -> Bool {
        let vm = FluxVM()
        return vm.validateNVMe()
    }

    func runNVMeBenchmark(targetMB: Int = 100) -> (Double, Double) {
        let vm = FluxVM()
        return vm.runNVMeBenchmark(targetMB: targetMB)
    }
}
