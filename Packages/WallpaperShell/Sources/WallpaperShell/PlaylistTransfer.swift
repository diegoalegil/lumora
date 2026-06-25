// SPDX-License-Identifier: MIT
// Provenance: clean-room. Export a playlist to a shareable JSON file and import one back. A playlist stores
// only wallpaper ids, so an imported playlist resolves to whatever of those wallpapers the importer actually
// has installed. Pure encode/decode — unit-tested; the file dialogs live in the app layer.
import Foundation
import WECore

public enum PlaylistTransfer {
    /// The file extension Lumora writes/reads for an exported playlist.
    public static let fileExtension = "lumoraplaylist"

    /// Serialize a playlist to pretty, stable JSON for export/sharing.
    public static func export(_ playlist: Playlist) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(playlist)
    }

    /// Decode a shared playlist, giving it a FRESH id so importing it (even one you exported yourself) adds a
    /// new playlist instead of overwriting an existing one with a matching id. The name is preserved.
    public static func makeImported(from data: Data) throws -> Playlist {
        var playlist = try JSONDecoder().decode(Playlist.self, from: data)
        playlist.id = UUID()
        return playlist
    }
}
