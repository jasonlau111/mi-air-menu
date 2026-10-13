import Foundation

@main struct ContractTests {
 static func main() throws {
  let decoder = JSONDecoder()
  let fixtures = [
   #"{"error":"二维码已过期，请重新扫码"}"#,
   #"{"devices":[]}"#,
   #"{"devices":[{"name":"测试空调","model":"xiaomi.aircondition.c16","ip":"192.0.2.1","mac":"00:00:00:00:00:00","token":"test-only","supported":true}]}"#,
   #"{"devices":[{"name":null,"model":"example.unsupported","ip":null,"mac":null,"token":null,"supported":false}]}"#,
   #"{"state":{"power":false,"mode":2,"target":26.5,"fan":0,"room":24.1,"eco":null,"sleep":null,"swing":null}}"#
  ]
  for fixture in fixtures { _ = try decoder.decode(Reply.self,from:Data(fixture.utf8)) }
  let actual = Process(), output = Pipe(), input = Pipe()
  actual.executableURL = URL(fileURLWithPath:CommandLine.arguments[1]);actual.standardOutput=output;actual.standardInput=input
  try actual.run();try input.fileHandleForWriting.write(contentsOf:Data("{}\n".utf8));try input.fileHandleForWriting.close()
  let bytes=output.fileHandleForReading.readDataToEndOfFile();actual.waitUntilExit()
  let reply=try decoder.decode(Reply.self,from:bytes)
  precondition(reply.error != nil && reply.state == nil)
  print("PASS: 5 response fixtures and real Rust error response")
 }
}
