//
//  PDFBuilder.swift
//  Osier — Module A: File & Hardware Manager
//
//  On-device PDF creation and modification using PDFKit.
//  Creates PDFs from plain text, attributed strings, or existing documents.
//  All output is written to the app's Documents directory unless a specific
//  destination URL is provided.
//

import Foundation
import PDFKit

// MARK: - PDF Build Request

/// Describes what kind of PDF to produce.
enum PDFBuildRequest {
    /// Create a new PDF from a plain-text string.
    case fromText(content: String, title: String, fontSize: CGFloat = 13)

    /// Create a new PDF from an attributed string (preserves formatting).
    case fromAttributedString(content: NSAttributedString, title: String)

    /// Merge multiple existing PDF files into one.
    case merge(sourceURLs: [URL], outputName: String)

    /// Append additional pages (from text) to an existing PDF.
    case appendText(to: URL, content: String)
}

// MARK: - PDFBuilder

final class PDFBuilder {

    // MARK: - Singleton

    static let shared = PDFBuilder()
    private init() {}

    // MARK: - Page Layout

    private let pageSize = CGSize(width: 612, height: 792)  // US Letter
    private let margin: CGFloat = 60
    private var contentRect: CGRect {
        CGRect(x: margin, y: margin,
               width: pageSize.width - margin * 2,
               height: pageSize.height - margin * 2)
    }

    // MARK: - Build Entry Point

    /// Builds a PDF according to the request and returns the output URL.
    @discardableResult
    func build(_ request: PDFBuildRequest, outputDirectory: URL? = nil) throws -> URL {
        let destDir = outputDirectory ?? FileSystemManager.shared.documentsURL

        switch request {
        case .fromText(let content, let title, let fontSize):
            return try buildFromText(content: content, title: title, fontSize: fontSize, outputDir: destDir)

        case .fromAttributedString(let content, let title):
            return try buildFromAttributedString(content: content, title: title, outputDir: destDir)

        case .merge(let sourceURLs, let outputName):
            return try merge(sources: sourceURLs, outputName: outputName, outputDir: destDir)

        case .appendText(let targetURL, let content):
            return try append(text: content, to: targetURL)
        }
    }

    // MARK: - From Text

    private func buildFromText(content: String, title: String, fontSize: CGFloat, outputDir: URL) throws -> URL {
        let font = UIFont.systemFont(ofSize: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraphStyle
        ]

        let attributed = NSAttributedString(string: content, attributes: attributes)
        return try buildFromAttributedString(content: attributed, title: title, outputDir: outputDir)
    }

    // MARK: - From NSAttributedString

    private func buildFromAttributedString(content: NSAttributedString, title: String, outputDir: URL) throws -> URL {
        let outputURL = outputDir.appendingPathComponent(sanitizeFilename(title)).appendingPathExtension("pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        let data = renderer.pdfData { ctx in
            let fullRange = NSRange(location: 0, length: content.length)
            var charIndex = 0

            while charIndex < content.length {
                ctx.beginPage()
                self.drawHeader(title: title, in: ctx.cgContext)

                // Draw content with text layout
                let layoutManager = NSLayoutManager()
                let textStorage   = NSTextStorage(attributedString: content)
                textStorage.addLayoutManager(layoutManager)

                let textContainer = NSTextContainer(size: CGSize(
                    width: self.contentRect.width,
                    height: self.contentRect.height - 20
                ))
                textContainer.lineFragmentPadding = 0
                layoutManager.addTextContainer(textContainer)

                // Glyph range that fits on this page
                let glyphRange = layoutManager.glyphRange(for: textContainer)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: self.contentRect.origin)

                let drawnRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                charIndex = drawnRange.upperBound

                if charIndex >= content.length { break }
            }
        }

        try data.write(to: outputURL)
        print("[PDFBuilder] ✅ Created: \(outputURL.lastPathComponent)")
        return outputURL
    }

    // MARK: - Merge

    private func merge(sources: [URL], outputName: String, outputDir: URL) throws -> URL {
        guard !sources.isEmpty else {
            throw PDFBuilderError.noSourcesProvided
        }

        let mergedDocument = PDFDocument()

        for sourceURL in sources {
            guard let doc = PDFDocument(url: sourceURL) else {
                throw PDFBuilderError.unreadableSource(sourceURL)
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    mergedDocument.insert(page, at: mergedDocument.pageCount)
                }
            }
        }

        let outputURL = outputDir.appendingPathComponent(sanitizeFilename(outputName)).appendingPathExtension("pdf")
        guard mergedDocument.write(to: outputURL) else {
            throw PDFBuilderError.writeFailed(outputURL)
        }

        print("[PDFBuilder] ✅ Merged \(sources.count) PDFs → \(outputURL.lastPathComponent)")
        return outputURL
    }

    // MARK: - Append Text

    private func append(text: String, to existingURL: URL) throws -> URL {
        guard let existingDoc = PDFDocument(url: existingURL) else {
            throw PDFBuilderError.unreadableSource(existingURL)
        }

        let newPageContent = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.black]
        )

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let appendData = renderer.pdfData { ctx in
            ctx.beginPage()
            newPageContent.draw(in: self.contentRect)
        }

        guard let appendDoc = PDFDocument(data: appendData) else {
            throw PDFBuilderError.renderFailed
        }

        for i in 0..<appendDoc.pageCount {
            if let page = appendDoc.page(at: i) {
                existingDoc.insert(page, at: existingDoc.pageCount)
            }
        }

        guard existingDoc.write(to: existingURL) else {
            throw PDFBuilderError.writeFailed(existingURL)
        }

        print("[PDFBuilder] ✅ Appended to: \(existingURL.lastPathComponent)")
        return existingURL
    }

    // MARK: - Header Drawing

    private func drawHeader(title: String, in context: CGContext) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray
        ]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: margin, y: margin / 2))

        // Separator line
        context.setStrokeColor(UIColor.lightGray.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: margin - 8))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: margin - 8))
        context.strokePath()
    }

    // MARK: - Helpers

    private func sanitizeFilename(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
    }
}

// MARK: - PDF Errors

enum PDFBuilderError: LocalizedError {
    case noSourcesProvided
    case unreadableSource(URL)
    case writeFailed(URL)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noSourcesProvided:          return "No source PDFs were provided for merge."
        case .unreadableSource(let url):  return "Could not read PDF: \(url.lastPathComponent)"
        case .writeFailed(let url):       return "Failed to write PDF to: \(url.lastPathComponent)"
        case .renderFailed:               return "PDF rendering failed."
        }
    }
}
