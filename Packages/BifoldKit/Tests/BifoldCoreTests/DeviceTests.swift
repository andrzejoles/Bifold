import Foundation
import Testing
@testable import BifoldCore

@Suite struct DeviceParserTests {
    @Test func afcLongListing() {
        let text = """
        drwxr-xr-x    1 mobile mobile        160 05 Mar 2026 10:11:12 100APPLE
        -rw-r--r--    1 mobile mobile    2345678 06 Mar 2026 08:00:01 IMG_0001.HEIC
        -rw-r--r--    1 mobile mobile         12 06 Mar 2026 08:00:01 Zdjęcie z wakacji.jpg
        lrwxrwxrwx    1 mobile mobile          4 01 Jan 2026 00:00:00 link
        """
        let dir = VFSPath(provider: ProviderID("device:x"), path: "/DCIM")
        let items = AFCDeviceFS.parseLongListing(text, in: dir)
        #expect(items.map(\.name) == ["100APPLE", "IMG_0001.HEIC", "Zdjęcie z wakacji.jpg", "link"])
        #expect(items[0].isDirectory && items[1].size == 2_345_678 && items[3].kind == .symlink)
        #expect(items[1].path.path == "/DCIM/IMG_0001.HEIC")
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.month, from: items[1].modified!) == 3)
    }

    @Test func mtpParsers() {
        let folders = """
        Friendly name: Pixel
        Storage: Internal shared storage
        3\tDCIM
        4\t  Camera
        9\tDownload
        """
        let f = MTPDeviceFS.parseFolders(folders)
        #expect(f.map(\.name) == ["DCIM", "Camera", "Download"])
        #expect(f[1].parent == 3 && f[0].parent == 0)
        let files = """
        File ID: 101
           Filename: PXL_2026.jpg
           File size 3456 (0x0000000000000D80) bytes
           Parent ID: 4
           Storage ID: 0x00010001
           Filetype: JPEG file
        File ID: 102
           Filename: dokument.pdf
           File size 99 (0x63) bytes
           Parent ID: 9
        """
        let parsed = MTPDeviceFS.parseFiles(files)
        #expect(parsed.count == 2 && parsed[0].size == 3456 && parsed[0].parent == 4 && parsed[1].name == "dokument.pdf")
        let detect = """
        libmtp version: 1.1.23

        Listing raw device(s)
        Device 0 (VID=18d1 and PID=4ee1) is a Google Inc Nexus/Pixel (MTP).
           Found 1 device(s):
           Google Inc: Nexus/Pixel (MTP) (18d1:4ee1) @ bus 0, dev 1
        Attempting to connect device(s)
        MTP-specific device properties:
           Model: Pixel 9
        """
        #expect(DeviceDetector.parseMTPDetect(detect).map(\.name) == ["Pixel 9"])
        #expect(DeviceDetector.parseMTPDetect("No raw devices found.").isEmpty)
    }

    @Test func noDevicesConnectedIsHandled() {
        #expect(DeviceDetector.iPhones(toolsDirectory: "/nonexistent").isEmpty)
        #expect(DeviceDetector.androids(toolsDirectory: "/nonexistent").isEmpty)
    }
}
