import QuickLookThumbnailing
import AppKit
import ImageIO

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {

        NSLog("X3FThumbnail: START")

        // ---------------------------------------------------------
        // Legge il file X3F
        // ---------------------------------------------------------

        guard let data = try? Data(contentsOf: request.fileURL) else {
            NSLog("X3FThumbnail: ERRORE lettura file")

            handler(nil, NSError(
                domain: "X3FThumbnail",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Impossibile leggere il file"
                ]
            ))

            return
        }

        NSLog("X3FThumbnail: file letto: \(data.count) bytes")

        // ---------------------------------------------------------
        // Estrae il JPEG embedded dall'X3F
        // ---------------------------------------------------------

        guard let jpegData = extractJPEG(from: data) else {
            NSLog("X3FThumbnail: ERRORE estrazione JPEG")

            handler(nil, NSError(
                domain: "X3FThumbnail",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Nessun JPEG trovato nel file X3F"
                ]
            ))

            return
        }

        NSLog("X3FThumbnail: JPEG estratto: \(jpegData.count) bytes")

        // ---------------------------------------------------------
        // Decodifica il JPEG con ImageIO
        // ---------------------------------------------------------

        guard let imageSource = CGImageSourceCreateWithData(
            jpegData as CFData,
            nil
        ) else {

            NSLog("X3FThumbnail: ERRORE CGImageSource")

            handler(nil, NSError(
                domain: "X3FThumbnail",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Impossibile creare CGImageSource"
                ]
            ))

            return
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            nil
        ) else {

            NSLog("X3FThumbnail: ERRORE CGImage")

            handler(nil, NSError(
                domain: "X3FThumbnail",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Impossibile decodificare JPEG"
                ]
            ))

            return
        }

        NSLog(
            "X3FThumbnail: CGImage OK \(cgImage.width)x\(cgImage.height)"
        )

        // ---------------------------------------------------------
        // Dimensione del thumbnail richiesta da Quick Look
        // ---------------------------------------------------------

        let contextSize = request.maximumSize

        NSLog("""
        X3FThumbnail: REQUEST
          maximumSize = \(request.maximumSize.width)x\(request.maximumSize.height)
          minimumSize = \(request.minimumSize.width)x\(request.minimumSize.height)
          scale = \(request.scale)
        """)

        NSLog(
            "X3FThumbnail: contextSize \(contextSize.width)x\(contextSize.height)"
        )

        // ---------------------------------------------------------
        // Mantiene le proporzioni originali del JPEG
        // e lo adatta al riquadro disponibile
        // ---------------------------------------------------------

        let imageSize = CGSize(
            width: cgImage.width,
            height: cgImage.height
        )

        let fitScale = min(
            contextSize.width / imageSize.width,
            contextSize.height / imageSize.height
        )

        let drawSize = CGSize(
            width: imageSize.width * fitScale,
            height: imageSize.height * fitScale
        )

        let origin = CGPoint(
            x: (contextSize.width - drawSize.width) / 2,
            y: (contextSize.height - drawSize.height) / 2
        )

        let drawRect = CGRect(
            origin: origin,
            size: drawSize
        )

        NSLog(
            "X3FThumbnail: drawRect \(drawRect)"
        )

        // ---------------------------------------------------------
        // Crea il thumbnail Quick Look
        // ---------------------------------------------------------

        let reply = QLThumbnailReply(
            contextSize: contextSize
        ) { context in

            NSLog("X3FThumbnail: DRAW")

            context.draw(
                cgImage,
                in: drawRect
            )

            NSLog("X3FThumbnail: DRAW OK")

            return true
        }

        NSLog("X3FThumbnail: REPLY")

        handler(reply, nil)

        NSLog("X3FThumbnail: END")
    }


    // =============================================================
    // Estrazione JPEG dalla struttura X3F
    // =============================================================

    private func extractJPEG(from data: Data) -> Data? {

        let bytes = [UInt8](data)

        guard bytes.count >= 8 else {
            return nil
        }

        // ---------------------------------------------------------
        // Header X3F: FOVb
        // ---------------------------------------------------------

        guard bytes[0] == 0x46,
              bytes[1] == 0x4F,
              bytes[2] == 0x56,
              bytes[3] == 0x62 else {

            NSLog("X3FThumbnail: header FOVb non trovato")

            return nil
        }

        NSLog("X3FThumbnail: header FOVb OK")

        // ---------------------------------------------------------
        // Offset della Directory Table
        // Gli ultimi 4 byte del file contengono l'offset
        // in little-endian.
        // ---------------------------------------------------------

        let directoryOffset = readUInt32LE(
            bytes,
            at: bytes.count - 4
        )

        let directory = Int(directoryOffset)

        NSLog(
            "X3FThumbnail: directory offset = \(directoryOffset)"
        )

        guard directory >= 0,
              directory + 12 <= bytes.count else {

            return nil
        }

        // ---------------------------------------------------------
        // Numero di entry nella Directory Table
        // ---------------------------------------------------------

        let numberOfEntries = Int(
            readUInt32LE(
                bytes,
                at: directory + 8
            )
        )

        NSLog(
            "X3FThumbnail: directory entries = \(numberOfEntries)"
        )

        // ---------------------------------------------------------
        // Cerca una sezione SECi contenente JPEG
        // ---------------------------------------------------------

        for index in 0..<numberOfEntries {

            let entryOffset = directory + 12 + (index * 12)

            guard entryOffset + 12 <= bytes.count else {
                return nil
            }

            let sectionOffset = Int(
                readUInt32LE(
                    bytes,
                    at: entryOffset
                )
            )

            let sectionSize = Int(
                readUInt32LE(
                    bytes,
                    at: entryOffset + 4
                )
            )

            guard sectionOffset >= 0,
                  sectionSize >= 28,
                  sectionOffset + sectionSize <= bytes.count else {

                continue
            }

            // -----------------------------------------------------
            // Identificatore della sezione: SECi
            // -----------------------------------------------------

            let sectionID = Array(
                bytes[
                    sectionOffset..<(sectionOffset + 4)
                ]
            )

            guard sectionID == [
                0x53,   // S
                0x45,   // E
                0x43,   // C
                0x69    // i
            ] else {

                continue
            }

            NSLog(
                "X3FThumbnail: SECi trovata, entry \(index)"
            )

            // -----------------------------------------------------
            // data_type e data_format
            // JPEG = data_type 2, data_format 18
            // -----------------------------------------------------

            let dataType = Int(
                readUInt32LE(
                    bytes,
                    at: sectionOffset + 8
                )
            )

            let dataFormat = Int(
                readUInt32LE(
                    bytes,
                    at: sectionOffset + 12
                )
            )

            NSLog(
                "X3FThumbnail: data_type=\(dataType) data_format=\(dataFormat)"
            )

            guard dataType == 2,
                  dataFormat == 18 else {

                continue
            }

            // -----------------------------------------------------
            // Dimensioni dichiarate del JPEG
            // -----------------------------------------------------

            let columns = Int(
                readUInt32LE(
                    bytes,
                    at: sectionOffset + 16
                )
            )

            let rows = Int(
                readUInt32LE(
                    bytes,
                    at: sectionOffset + 20
                )
            )

            NSLog(
                "X3FThumbnail: JPEG \(columns)x\(rows)"
            )

            // -----------------------------------------------------
            // La parte JPEG inizia 28 byte dopo l'inizio
            // della sezione SECi.
            // -----------------------------------------------------

            let jpegOffset = sectionOffset + 28
            let jpegSize = sectionSize - 28

            guard jpegSize > 0,
                  jpegOffset + jpegSize <= bytes.count else {

                return nil
            }

            NSLog(
                "X3FThumbnail: JPEG offset = \(jpegOffset)"
            )

            NSLog(
                "X3FThumbnail: JPEG size = \(jpegSize)"
            )

            return data.subdata(
                in: jpegOffset..<(jpegOffset + jpegSize)
            )
        }

        return nil
    }


    // =============================================================
    // Lettura UInt32 little-endian
    // =============================================================

    private func readUInt32LE(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32 {

        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
