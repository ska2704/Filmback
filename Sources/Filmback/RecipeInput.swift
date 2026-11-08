import CoreFoundation
import Foundation
import ImageIO
import Vision

enum RecipeInput {
    private static let maximumPageBytes = 5 * 1_024 * 1_024
    private static let maximumImageBytes = 40 * 1_024 * 1_024

    static func text(from url: URL) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard url.isFileURL else { throw InputError.localFileRequired }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let fileExtension = url.pathExtension.lowercased()
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]
            let textExtensions: Set<String> = ["txt", "json", "ofr", "csv", "md"]
            let isImage = imageExtensions.contains(fileExtension)
            guard isImage || textExtensions.contains(fileExtension) else {
                throw InputError.unsupportedFile
            }

            let limit = isImage ? maximumImageBytes : maximumPageBytes
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true else { throw InputError.localFileRequired }
            if let size = attributes.fileSize, size > limit {
                throw InputError.fileTooLarge(isImage: isImage)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= limit else { throw InputError.fileTooLarge(isImage: isImage) }
            try Task.checkCancellation()

            if isImage { return try recognizeImage(data) }
            guard let text = String(data: data, encoding: .utf8) else {
                throw InputError.invalidUTF8
            }
            return try nonempty(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func fetchPage(_ url: URL) async throws -> String {
        guard isWebURL(url), url.user == nil, url.password == nil else {
            throw InputError.invalidURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: PublicPageDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("Filmback/1.0 (macOS; public recipe import)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, application/xhtml+xml, text/plain, application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url, isWebURL(finalURL) else {
            throw InputError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw InputError.httpStatus(response.statusCode)
        }
        guard response.expectedContentLength <= Int64(maximumPageBytes) else {
            throw InputError.pageTooLarge
        }
        let mimeType = response.mimeType?.lowercased()
        if let mimeType,
           mimeType != "text/html", mimeType != "application/xhtml+xml",
           mimeType != "text/plain", mimeType != "application/json",
           !mimeType.hasSuffix("+json") {
            throw InputError.unsupportedPage(mimeType)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumPageBytes else { throw InputError.pageTooLarge }
            data.append(byte)
        }
        let text = try decodePage(data, encodingName: response.textEncodingName)
        let isHTML = mimeType == "text/html" || mimeType == "application/xhtml+xml"
            || (mimeType == nil && text.range(of: #"<(?:!doctype\s+html|html|body)\b"#,
                                              options: [.regularExpression, .caseInsensitive]) != nil)
        return try nonempty(isHTML ? plainText(fromHTML: text) : text)
    }

    private static func recognizeImage(_ data: Data) throws -> String {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else { throw InputError.invalidImage }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        if let properties,
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           width.doubleValue * height.doubleValue > 80_000_000 {
            throw InputError.imageDimensionsTooLarge
        }

        let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.qr]
        do {
            try handler.perform([barcodeRequest])
        } catch {
            throw InputError.imageRecognition(error.localizedDescription)
        }
        try Task.checkCancellation()
        let payloads = Array(Set((barcodeRequest.results ?? []).compactMap { $0.payloadStringValue }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        guard payloads.count <= 1 else { throw InputError.multipleQRCodes }
        if let payload = payloads.first { return payload }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        do {
            try handler.perform([request])
        } catch {
            throw InputError.imageRecognition(error.localizedDescription)
        }
        try Task.checkCancellation()
        let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in observations {
            if let anchor = rows.last?.first,
               abs(anchor.boundingBox.midY - observation.boundingBox.midY)
                < max(0.004, min(anchor.boundingBox.height, observation.boundingBox.height) * 0.5) {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        let text = rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputError.noRecognizedText
        }
        return text
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    private static func nonempty(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InputError.emptyText }
        return text
    }

    private static func decodePage(_ data: Data, encodingName: String?) throws -> String {
        if let encodingName {
            let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        throw InputError.invalidPageEncoding
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        let transformations: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"<(script|style|noscript|svg|head|template)\b[^>]*>[\s\S]*?</\1\s*>"#, ""),
            (#"</(?:td|th)\s*>\s*<(?:td|th)\b[^>]*>"#, ": "),
            (#"</dt\s*>\s*<dd\b[^>]*>"#, ": "),
            (#"</?(?:address|article|aside|blockquote|br|caption|dd|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|table|tbody|tfoot|thead|tr|ul)\b[^>]*>"#, "\n"),
            (#"<[^>]*>"#, "")
        ]
        for (pattern, replacement) in transformations {
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = decodeEntities(text)
        return text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"[\t\u00A0 ]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func decodeEntities(_ text: String) -> String {
        let entities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "–", "mdash": "—", "minus": "−", "plusmn": "±", "deg": "°",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…",
            "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
            "times": "×", "divide": "÷", "ensp": " ", "emsp": " ", "thinsp": " ",
            "eacute": "é", "Eacute": "É", "aacute": "á", "agrave": "à", "uuml": "ü",
            "ouml": "ö", "auml": "ä", "ntilde": "ñ", "ccedil": "ç"
        ]
        guard let expression = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#X[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);"#) else {
            return text
        }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let wholeRange = Range(match.range, in: result) else { continue }
            let value = String(text[valueRange])
            var decoded = entities[value]
            if value.hasPrefix("#") {
                let hexadecimal = value.lowercased().hasPrefix("#x")
                let digits = value.dropFirst(hexadecimal ? 2 : 1)
                if let number = UInt32(digits, radix: hexadecimal ? 16 : 10),
                   number != 0, let scalar = Unicode.Scalar(number) {
                    decoded = String(scalar)
                }
            }
            if let decoded { result.replaceSubrange(wholeRange, with: decoded) }
        }
        return result
    }

    private final class PublicPageDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, RecipeInput.isWebURL(url), url.user == nil, url.password == nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private enum InputError: LocalizedError {
        case localFileRequired, unsupportedFile, invalidUTF8, emptyText, invalidImage
        case fileTooLarge(isImage: Bool), imageDimensionsTooLarge, imageRecognition(String)
        case multipleQRCodes, noRecognizedText, invalidURL, invalidResponse, httpStatus(Int)
        case pageTooLarge, unsupportedPage(String), invalidPageEncoding

        var errorDescription: String? {
            switch self {
            case .localFileRequired: return "Choose a recipe file or image saved on your Mac."
            case .unsupportedFile: return "Choose a TXT, JSON, OFR, CSV or Markdown file, or a PNG, JPEG, HEIC or TIFF image."
            case .invalidUTF8: return "This recipe file is not UTF-8 text. Export it as UTF-8 and try again."
            case .emptyText: return "No recipe text was found in this file or page."
            case .invalidImage: return "This image could not be opened. Try exporting it as PNG or JPEG."
            case .fileTooLarge(let isImage): return isImage ? "Choose an image smaller than 40 MB." : "Choose a recipe file smaller than 5 MB."
            case .imageDimensionsTooLarge: return "This image is too large to scan. Crop it to the recipe or resize it below 80 megapixels."
            case .imageRecognition(let detail): return "The image could not be scanned: \(detail)"
            case .multipleQRCodes: return "Several QR codes were found. Crop the image to the recipe code you want to import."
            case .noRecognizedText: return "No readable recipe text or QR code was found. Try a clearer image or crop around the recipe."
            case .invalidURL: return "Enter a public http:// or https:// recipe URL without a username or password."
            case .invalidResponse: return "The site did not return a readable web response."
            case .httpStatus(let code):
                if code == 401 || code == 403 { return "This page requires access the app does not have (HTTP \(code)). Paste recipe text you can access, or import a saved screenshot."
                }
                return "The site returned HTTP \(code). Check the URL or paste the recipe text."
            case .pageTooLarge: return "This page is larger than 5 MB. Paste the recipe text or import a screenshot instead."
            case .unsupportedPage(let type): return "The URL returned \(type). Use a recipe webpage, plain text or JSON URL."
            case .invalidPageEncoding: return "The page's text encoding could not be read. Copy and paste the recipe text instead."
            }
        }
    }
}
