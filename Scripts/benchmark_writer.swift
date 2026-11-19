import AppKit
import Foundation

@main
enum WriterBenchmark {
    static func main() {
        let paragraph = "Une idée claire pour le projet. #projet Écrire vite et retrouver ses notes facilement.\n"
        let text = "# Très long document\n\n" + String(repeating: paragraph, count: 2_000)
        let storage = NSTextStorage(string: text)
        let configuration = WriterConfiguration()
        measure("Mise en forme complète 180 Ko", iterations: 5) {
            WriterStyling.apply(to: storage, text: text, selection: NSRange(location: 0, length: 0), configuration: configuration)
        }
        measure("Mise en forme visible 180 Ko", iterations: 30) {
            WriterStyling.apply(to: storage, text: text, range: NSRange(location: 90_000, length: 5_000),
                                selection: NSRange(location: 92_000, length: 0), configuration: configuration)
        }
        measure("Concentration avec curseur hors écran 180 Ko", iterations: 30) {
            WriterStyling.apply(to: storage, text: text, range: NSRange(location: 0, length: 5_000),
                                selection: NSRange(location: storage.length, length: 0),
                                configuration: WriterConfiguration(focus: .sentence))
        }
        measure("Analyse grammaticale visible", iterations: 5) {
            _ = WriterStyling.grammarHighlights(in: text, around: NSRange(location: 90_000, length: 2_000))
        }
        let highlights = WriterStyling.grammarHighlights(in: text, around: NSRange(location: 90_000, length: 2_000))
        measure("Application grammaticale visible", iterations: 5) {
            WriterStyling.applyGrammar(highlights, to: storage, text: text,
                                       selection: NSRange(location: 0, length: 0), configuration: configuration)
        }
    }

    private static func measure(_ name: String, iterations: Int, _ operation: () -> Void) {
        var samples: [Double] = []
        for index in 0...iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            operation()
            if index > 0 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        }
        samples.sort()
        print(String(format: "%@: médiane %.2f ms · p95 %.2f ms", name, samples[samples.count / 2], samples[Int(ceil(Double(samples.count) * 0.95)) - 1]))
    }
}
