import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BifoldCore

/// Przeglądarka F3: rozpoznanie rodzaju pliku (sygnatury, rozszerzenia, tekst) i informacje o obrazie.
@Suite struct ViewerDetectionTests {
    static func bytes(_ b: [UInt8], padding: Int = 64) -> Data { Data(b + [UInt8](repeating: 0, count: padding)) }

    @Test func signaturesWinOverExtension() {
        #expect(ViewerDetection.detect(name: "bez-rozszerzenia", sample: Self.bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .image)
        #expect(ViewerDetection.detect(name: "zdjecie.txt", sample: Self.bytes([0xFF, 0xD8, 0xFF, 0xE0])) == .image)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes(Array("%PDF-1.7".utf8))) == .pdf)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes([0, 0, 0, 0x20] + Array("ftypisom".utf8))) == .video)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes([0, 0, 0, 0x18] + Array("ftypqt  ".utf8))) == .video)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes([0, 0, 0, 0x18] + Array("ftypheic".utf8))) == .image)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes([0, 0, 0, 0x18] + Array("ftypM4A ".utf8))) == .audio)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8))) == .audio)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes(Array("ID3".utf8))) == .audio)
        #expect(ViewerDetection.detect(name: "x", sample: Self.bytes([0x1A, 0x45, 0xDF, 0xA3])) == .video)
    }

    @Test func extensionsForBinaryData() {
        let binary = Self.bytes([0x00, 0x01, 0x02, 0x03], padding: 200)
        #expect(ViewerDetection.detect(name: "film.mov", sample: binary) == .video)
        #expect(ViewerDetection.detect(name: "utwór.aiff", sample: binary) == .audio)
        #expect(ViewerDetection.detect(name: "raport.docx", sample: binary) == .document)
        #expect(ViewerDetection.detect(name: "arkusz.xlsx", sample: binary) == .document)
        #expect(ViewerDetection.detect(name: "font.ttf", sample: binary) == .document)
        #expect(ViewerDetection.detect(name: "program", sample: binary) == .binary)
        // Pusty plik z rozszerzeniem obrazu — podgląd (pokaże komunikat), nie pusty tekst.
        #expect(ViewerDetection.detect(name: "pusty.png", sample: Data()) == .image)
    }

    @Test func textWithLanguage() {
        let text = Data("let x = 1\n".utf8)
        #expect(ViewerDetection.detect(name: "main.swift", sample: text) == .text(language: "swift"))
        #expect(ViewerDetection.detect(name: "Makefile", sample: text) == .text(language: "makefile"))
        #expect(ViewerDetection.detect(name: "notatki.txt", sample: text) == .text(language: nil))
        #expect(ViewerDetection.detect(name: "pakiet.PKB", sample: text) == .text(language: "sql"))
        // Tekst z rozszerzeniem obrazu (np. zapisany błędnie) — tekst, nie pusty obraz.
        #expect(ViewerDetection.detect(name: "nie-obraz.png", sample: text) == .text(language: nil))
        // SVG to obraz (wektorowy), choć jest tekstem.
        #expect(ViewerDetection.detect(name: "ikona.svg", sample: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == .image)
    }

    @Test func shebang() {
        #expect(ViewerDetection.language(forName: "skrypt", sample: Data("#!/usr/bin/env python3\nprint(1)\n".utf8)) == "python")
        #expect(ViewerDetection.language(forName: "run", sample: Data("#!/bin/bash\necho\n".utf8)) == "bash")
        #expect(ViewerDetection.language(forName: "run", sample: Data("#!/bin/sh\n".utf8)) == "bash")
        #expect(ViewerDetection.language(forName: "plik", sample: Data("zwykły tekst\n".utf8)) == nil)
    }

    @Test func imageInfoFromGeneratedPNG() throws {
        let tmp = try TempDir()
        let url = tmp.url.appending(path: "obraz.png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let info = try #require(ImageInfo.read(url))
        #expect(info.width == 40 && info.height == 30)
        #expect(info.format == "PNG")
        #expect(info.colorModel == "RGB" && info.hasAlpha)
        #expect(info.frames == 1)
        #expect(info.summary.hasPrefix("40 × 30 px · PNG · RGB"))
        #expect(ViewerDetection.detect(name: "obraz", sample: try Data(contentsOf: url)) == .image)
        #expect(ImageInfo.read(tmp.url.appending(path: "brak.png")) == nil)
    }
}
