import Foundation

struct BindingInfo: Codable { var name: String; var ip: String; var mac: String; var token: String }
struct ACState: Codable { var power: Bool; var mode: Int; var target: Double; var eco: Bool?; var sleep: Bool?; var fan: Int; var swing: Bool?; var room: Double? }
struct Candidate: Codable, Identifiable { var name: String?; var model: String; var ip: String?; var mac: String?; var token: String?; var supported: Bool; var id: String { mac ?? model } }
struct Reply: Decodable { var error: String?; var state: ACState?; var devices: [Candidate]? }
