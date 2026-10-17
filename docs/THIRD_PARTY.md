# Biblioteki i narzędzia zewnętrzne

| Komponent | Wersja | Licencja | Sposób użycia | Etap |
|---|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.99.0 | MIT | SPM, `LocalProcessTerminalView` — terminal i panele agentów | 1 |
| [HexFiend](https://github.com/HexFiend/HexFiend) | 2.18.1 | BSD-2-Clause | submoduł, `HexFiend.framework` — podgląd hex | 1 |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache-2.0 / MIT (w trakcie zmiany licencji) | SPM — serwer MCP w aplikacji, transport stdio w moście | 2 |
| [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) | 15.2.0 (Homebrew) | MIT / Unlicense | proces, `--json` | 3 |
| [7-Zip](https://www.7-zip.org) (`7zz`) | 26.04 (Homebrew `sevenzip`) | LGPL-2.1 + unRAR | proces | 4 |
| [rclone](https://rclone.org) | 1.75.2 (Homebrew) | MIT | proces `rclone rcd` | 5–6 |
| [libmtp](https://libmtp.sourceforge.net) | Homebrew | LGPL-2.1 | biblioteka dynamiczna | 7 |
| [libimobiledevice](https://libimobiledevice.org) | Homebrew | LGPL-2.1 | biblioteka dynamiczna / narzędzia | 7 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.46.0 (Homebrew) | MIT | narzędzie deweloperskie (generuje projekt) | 1 |

Frameworki systemowe: AppKit, SwiftUI, Foundation, CryptoKit, QuickLookUI, QuickLookThumbnailing,
UniformTypeIdentifiers, CoreServices (FSEvents), DiskArbitration, Security, ImageIO, AVFoundation,
NetFS, ServiceManagement.

Licencje (L)GPL są dopuszczalne — aplikacja jest wyłącznie do użytku prywatnego.
