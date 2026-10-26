# Biblioteki i narzędzia zewnętrzne

| Komponent | Wersja | Licencja | Sposób użycia | Etap |
|---|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.99.1 | MIT | SPM, `LocalProcessTerminalView` — terminal i panele agentów | 1 |
| [HexFiend](https://github.com/HexFiend/HexFiend) | 2.18.1 | BSD-2-Clause | submoduł, `HexFiend.framework` — podgląd hex | 1 |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache-2.0 / MIT (w trakcie zmiany licencji) | SPM — serwer MCP w aplikacji, transport stdio w moście | 2 |
| [swift-log](https://github.com/apple/swift-log) | 1.16.2 | Apache-2.0 | SPM (zależność MCP Swift SDK i `BifoldAgent`) — linkowana statycznie | 2 |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 | SPM (zależność MCP Swift SDK) — linkowana statycznie | 2 |
| [eventsource](https://github.com/mattt/eventsource) | 1.5.1 | MIT | SPM (zależność MCP Swift SDK) — linkowana statycznie | 2 |
| [Sparkle](https://sparkle-project.org) | 2.10.1 | MIT | SPM — automatyczne aktualizacje (podpis EdDSA) | wydania |
| [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) | 15.2.0 (Homebrew) | MIT / Unlicense | proces, `--json` | 3 |
| [7-Zip](https://www.7-zip.org) (`7zz`) | 26.05 (Homebrew `sevenzip`) | LGPL-2.1 + unRAR | proces | 4 |
| [rclone](https://rclone.org) | 1.75.2 (Homebrew) | MIT | proces `rclone rcd` | 5–6 |
| [libmtp](https://libmtp.sourceforge.net) | Homebrew | LGPL-2.1 | pomocnik `bifold-mtp` (własny program w pakiecie, osobny proces) linkuje libmtp dynamicznie z Homebrew; biblioteka nie jest dołączana | 7 |
| [libimobiledevice](https://libimobiledevice.org) | Homebrew | LGPL-2.1 | proces (`afcclient`, `idevice_id`) | 7 |
| OpenSSH (`ssh`, `scp`) | systemowy | BSD | proces — SCP i zapamiętywanie kluczy serwerów | 5 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.46.0 (Homebrew) | MIT | narzędzie deweloperskie (generuje projekt) | 1 |

Frameworki systemowe: AppKit, SwiftUI, Foundation, CryptoKit, QuickLookUI, QuickLookThumbnailing,
UniformTypeIdentifiers, CoreServices (FSEvents), DiskArbitration, Security, ImageIO, AVFoundation,
NetFS, ServiceManagement.

Bifold jest na licencji MIT. Do aplikacji dołączane są tylko biblioteki na licencjach MIT, BSD
i Apache 2.0 (SwiftTerm, HexFiend, Sparkle, MCP Swift SDK i jego zależności swift-log, swift-system,
eventsource); ich teksty trafiają do `Bifold.app/Contents/Resources/Licencje zewnętrzne.txt` i do obrazu
DMG (`scripts/third-party-licenses.sh`). Pozostałe pakiety pobierane przez SPM (swift-nio,
swift-collections, swift-atomics, swift-argument-parser, swift-png, h) służą tylko celom
niebudowanym dla aplikacji na macOS (narzędzia i testy zależności) i nie trafiają do pakietu.
Programy na licencjach (L)GPL i unRAR (7-Zip, libimobiledevice) nie są dołączane ani linkowane —
użytkownik instaluje je sam, Bifold uruchamia je jako osobne procesy. libmtp też nie jest dołączana:
linkuje ją dynamicznie (z Homebrew u użytkownika) tylko pomocnik `bifold-mtp` — własny program
w `Contents/MacOS`, uruchamiany jako osobny proces; główny program aplikacji jej nie linkuje.
