//
//  SupabaseJSON.swift
//  WorkHaven
//

import Foundation

enum SupabaseJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            
            if container.decodeNil() {
                throw DecodingError.valueNotFound(
                    Date.self,
                    .init(codingPath: container.codingPath, debugDescription: "Expected date string")
                )
            }
            
            let value = try container.decode(String.self)
            if let date = fractional.date(from: value) ?? standard.date(from: value) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date: \(value)"
            )
        }
        
        return decoder
    }
}
