import AppKit
import SwiftUI
import Security
import Observation

enum AppFailure: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }

@MainActor enum Vault {
 static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MiAirMenu", kSecAttrAccount as String: "device"]
 static func load() throws -> BindingInfo? {
  var q = base; q[kSecReturnData as String] = true; var result: CFTypeRef?
  let status = SecItemCopyMatching(q as CFDictionary, &result)
  if status == errSecItemNotFound { return nil }
  guard status == errSecSuccess, let data = result as? Data else { throw AppFailure.message("无法读取钥匙串，请检查系统授权") }
  return try JSONDecoder().decode(BindingInfo.self, from: data)
 }
 static func save(_ info: BindingInfo) throws {
  let data = try JSONEncoder().encode(info)
  let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
  if update == errSecItemNotFound {
   var q = base; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
   guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AppFailure.message("无法保存到钥匙串") }
  } else if update != errSecSuccess { throw AppFailure.message("无法更新钥匙串") }
 }
}

@concurrent func readPipe(_ handle: FileHandle) async -> Data { handle.readDataToEndOfFile() }

@MainActor final class Bridge {
 var process: Process?
 func call(_ request: [String: Any]) async throws -> Reply {
  guard process == nil else { throw AppFailure.message("操作进行中") }
  guard let root = Bundle.main.resourceURL else { throw AppFailure.message("应用资源缺失") }
  let input = Pipe(), output = Pipe(); let p = Process()
  p.executableURL = root.appendingPathComponent("mi-air-core")
  p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
  let data = try JSONSerialization.data(withJSONObject: request)
  try p.run(); process = p
  defer { if p.isRunning { p.terminate() }; process = nil; try? output.fileHandleForReading.close() }
  async let collected = readPipe(output.fileHandleForReading)
  do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])); try input.fileHandleForWriting.close() } catch { p.terminate(); throw error }
  let deadline = Date().addingTimeInterval(request["op"] as? String == "pair" ? 180 : 35)
  do {
   while p.isRunning {
    try await Task.sleep(for: .milliseconds(100))
    if Date() > deadline { p.terminate(); throw AppFailure.message("连接超时，请重试") }
   }
  } catch { if p.isRunning { p.terminate() }; throw error }
  let bytes = await collected
  guard p.terminationStatus == 0, !bytes.isEmpty else { throw AppFailure.message("连接已结束，请重新尝试") }
  let reply: Reply
  do { reply = try JSONDecoder().decode(Reply.self, from: bytes) }
  catch { throw AppFailure.message("设备返回数据无法解析，请重试；持续出现时请反馈给开发者") }
  if let message = reply.error { throw AppFailure.message(message) }
  return reply
 }
 func cancel() { process?.terminate() }
}

@MainActor @Observable final class Model {
 var panelHeight: CGFloat = 560; var isPreview = false; var state: ACState?; var binding: BindingInfo?; var online = false; var busy = false
 var message = "绑定后即可在这里控制空调"; var settings = false; var pairing = false
 var qr: NSImage?; var candidates: [Candidate] = []; var region = "cn"; var address = ""
 var editing = false; var lastRead: Date?; var pairTask: Task<Void,Never>?
 let bridge = Bridge(); var onState: (() -> Void)?
 var temperature: Double = 26
 init(preview: Bool = false) {
  if preview { isPreview = true; state = ACState(power: true, mode: 2, target: 23, eco: true, sleep: false, fan: 0, swing: true, room: 24.1); temperature = 23; online = true; message = "界面预览 · 示例数据"; return }
  do { binding = try Vault.load(); address = binding?.ip ?? ""; if binding != nil { message = "正在连接空调" } } catch { message = error.localizedDescription }
 }
 func refresh() async {
  guard let binding, !busy, !pairing, !editing else { return }; busy = true; defer { busy = false }
  do { let r = try await bridge.call(request(binding, op: "read")); try accept(r) } catch { online = false; message = error.localizedDescription; onState?() }
 }
 func request(_ info: BindingInfo, op: String) -> [String:Any] { ["op":op,"ip":info.ip,"mac":info.mac,"token":info.token] }
 func accept(_ reply: Reply) throws {
  guard let s = reply.state else { throw AppFailure.message("未读到完整设备状态") }
  state = s; temperature = s.target; online = true; lastRead = Date(); message = "局域网已连接"; onState?()
 }
 func set(_ key: String, _ value: Any) {
  guard let binding, online, !busy, !pairing else { return }
  busy = true
  Task {
   defer { busy = false }
   do { var req = request(binding,op:"set"); req["key"] = key; req["value"] = value
    let result = try await bridge.call(req); try accept(result)
   } catch { online = false; message = error.localizedDescription; temperature = state?.target ?? 26; onState?() }
  }
 }
 func pair() {
  guard !busy, !pairing else { return }; pairing = true; qr = nil; candidates = []; message = "正在生成二维码…"
  pairTask = Task {
   let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
   do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir); pairing = false; qr = nil }
    let file = dir.appendingPathComponent("login.png")
    let watcher = Task {
     while !Task.isCancelled {
      if let image = NSImage(contentsOf: file) { qr = image; message = "用米家 App 扫码，并在手机上确认登录"; break }
      try? await Task.sleep(for: .milliseconds(250))
     }
    }
    defer { watcher.cancel() }
    let result = try await bridge.call(["op":"pair","region":region,"qr":file.path])
    candidates = result.devices ?? []; message = candidates.isEmpty ? "该地区未找到空调，请检查米家地区后重试" : "选择要绑定的空调"
   } catch { pairing = false; qr = nil; message = error is CancellationError ? "已取消绑定" : error.localizedDescription }
  }
 }
 func cancelPair() { pairTask?.cancel(); bridge.cancel() }
 func choose(_ device: Candidate) {
  guard device.supported, let mac = device.mac, let token = device.token, let ip = device.ip, !ip.isEmpty else { message = "设备没有局域网地址，请先在米家中联网"; return }
  let info = BindingInfo(name: device.name ?? "米家空调",ip:ip,mac:mac,token:token)
  busy = true
  Task {
   defer { busy = false }
   do { let result = try await bridge.call(request(info,op:"read")); try accept(result); try Vault.save(info); binding = info; address = ip; candidates = []; settings = false }
   catch { online = false; message = error.localizedDescription }
  }
 }
 func updateAddress() {
  guard var info = binding, !busy else { return }; info.ip = address.trimmingCharacters(in:.whitespacesAndNewlines); busy = true
  Task { defer { busy = false }; do { let result = try await bridge.call(request(info,op:"read")); try accept(result); try Vault.save(info); binding = info } catch { online = false; message = error.localizedDescription } }
 }
}

let muted = Color(red:0.60,green:0.61,blue:0.57)
let cream = Color(red:0.88,green:0.89,blue:0.80)
struct ACIllustration: View {
 var powered = false
 @Environment(\.accessibilityReduceMotion) private var reduceMotion
 var body: some View {
  ZStack {
   Ellipse().fill(.black.opacity(0.8)).frame(width:220,height:24).blur(radius:12).offset(y:43)
   RoundedRectangle(cornerRadius:10).fill(LinearGradient(colors:[.white,Color(white:0.72)],startPoint:.top,endPoint:.bottom)).frame(width:220,height:70).rotationEffect(.degrees(3)).shadow(color:.white.opacity(0.12),radius:16)
   VStack(spacing:6) {
    HStack { Text("MIJIA").font(.system(size:7,weight:.medium)).foregroundStyle(.gray); Spacer(); Circle().fill(Color.green.opacity(0.7)).frame(width:3,height:3) }.padding(.horizontal,14)
    Rectangle().fill(Color.black.opacity(0.06)).frame(height:1)
    RoundedRectangle(cornerRadius:3).fill(Color(white:0.13)).frame(height:15).overlay {
     HStack(spacing:6) { ForEach(0..<29,id:\.self) { _ in Rectangle().fill(Color(white:0.45)).frame(width:1) } }.padding(.horizontal,8)
    }
   }.padding(.horizontal,7).frame(width:220).offset(y:14).rotationEffect(.degrees(3))
   if powered { Image(systemName:"wind").font(.system(size:30,weight:.ultraLight)).foregroundStyle(cream.opacity(0.25)).offset(y:64).transition(.opacity) }
  }.animation(reduceMotion ? nil : .easeOut(duration:0.2),value:powered).frame(height:110).accessibilityLabel("壁挂式空调")
 }
}
struct Panel: View {
 @Environment(\.accessibilityReduceMotion) private var reduceMotion
 @Bindable var m: Model
 var body: some View {
  VStack(spacing:0) {
   if m.settings { ScrollView { setup.frame(maxWidth:.infinity,alignment:.topLeading) }.transition(.opacity) } else { ScrollView { dashboard }.transition(.opacity) }
  }.padding(24).frame(width:430,height:m.panelHeight,alignment:.top).clipped().background(LinearGradient(colors:[Color(white:0.065),Color(white:0.025)],startPoint:.topLeading,endPoint:.bottomTrailing))
   .foregroundStyle(cream).preferredColorScheme(.dark)
   .animation(reduceMotion ? nil : .easeOut(duration:0.18), value:m.settings)
 }
 var dashboard: some View {
  VStack(spacing:14) {
   HStack {
    Image(systemName:"thermometer.medium").foregroundStyle(muted)
    Text(!m.online && m.state != nil ? "上次室温" : "室温").font(.system(size:13,weight:.medium))
    Text(m.state?.room.map { String(format:"%.1f°",$0) } ?? "—").font(.system(size:14,weight:.semibold)).monospacedDigit()
    Spacer()
    Button { if let s=m.state { m.set("power",!s.power) } } label: {
     Image(systemName:"power").font(.system(size:23,weight:.medium)).frame(width:44,height:44).background(Circle().fill(m.state?.power == true ? cream.opacity(0.17) : .white.opacity(0.045)))
    }.buttonStyle(PressStyle()).disabled(!m.online || m.busy).help("开关空调").accessibilityLabel("开关空调")
   }
   ACIllustration(powered: m.online && m.state?.power == true)
   HStack(alignment:.bottom) {
    HStack(alignment:.firstTextBaseline,spacing:2) {
     Text(m.state == nil ? "—" : format(m.temperature)).font(.system(size:58,weight:.medium,design:.rounded)).tracking(-3).monospacedDigit().contentTransition(.numericText(value:m.temperature)).animation(reduceMotion || m.editing ? nil : .easeOut(duration:0.16),value:m.temperature)
     Text("°C").font(.system(size:22,weight:.medium)).foregroundStyle(muted)
    }
    Spacer()
    Button { m.set("eco",!(m.state?.eco ?? false)) } label: {
     HStack(spacing:10) { Image(systemName:"leaf.fill"); Text("节能"); Capsule().fill(m.state?.eco == true ? cream.opacity(0.35):Color.white.opacity(0.09)).frame(width:38,height:23).overlay(alignment:m.state?.eco == true ? .trailing:.leading) { Circle().fill(cream).frame(width:19,height:19).padding(2) } }.font(.system(size:13,weight:.medium)).padding(12).background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:12))
    }.buttonStyle(PressStyle()).animation(reduceMotion ? nil:.spring(response:0.22,dampingFraction:0.9),value:m.state?.eco).disabled(!m.online || m.busy || m.state?.eco == nil).accessibilityLabel("节能模式").accessibilityValue(m.state?.eco == true ? "开启":"关闭")
   }
   VStack(spacing:8) {
    HStack(spacing:12) {
     roundButton("minus","降低温度") { m.set("target",max(16,m.temperature-0.5)) }
     TemperatureTrack(value:$m.temperature,editing:$m.editing) {m.set("target",m.temperature)}.disabled(!m.online || m.busy)
     roundButton("plus","升高温度") { m.set("target",min(31,m.temperature+0.5)) }
    }
    HStack { Text("16°"); Spacer(); Text("31°") }.font(.system(size:10,weight:.medium)).foregroundStyle(muted).padding(.horizontal,51)
   }
   HStack(spacing:8) {
    OptionTile(icon:"snowflake",title:"模式",value:m.state.map {mode($0.mode)} ?? "—",choices:[(2,"制冷"),(5,"制热"),(3,"除湿"),(4,"送风")]) {m.set("mode",$0)}
    OptionTile(icon:"fan",title:"风速",value:m.state.map {$0.fan == 0 ? "自动":"\($0.fan) 档"} ?? "—",choices:(0..<8).map{($0,$0 == 0 ? "自动":"\($0) 档")}) {m.set("fan",$0)}
    OptionTile(icon:"moon",title:"睡眠",value:m.state?.sleep.map{$0 ? "开启":"关闭"} ?? "—",choices:[(1,"开启"),(0,"关闭")]) {m.set("sleep",$0 == 1)}.disabled(m.state?.sleep == nil)
    OptionTile(icon:"wind",title:"摆风",value:m.state?.swing.map{$0 ? "上下":"关闭"} ?? "—",choices:[(1,"上下摆风"),(0,"停止摆风")]) {m.set("swing",$0 == 1)}.disabled(m.state?.swing == nil)
   }.disabled(!m.online || m.busy)
   if m.binding == nil && !m.isPreview {
    Button("绑定米家空调") {m.settings=true}.buttonStyle(.borderedProminent).tint(cream).foregroundStyle(.black).controlSize(.large)
   }
   HStack(alignment:.center,spacing:7) {
    Circle().fill(m.online ? Color(red:0.61,green:0.73,blue:0.51):muted).frame(width:5,height:5)
    Text(m.busy ? "正在同步…":m.message).font(.system(size:11)).foregroundStyle(muted).lineLimit(2)
    Spacer(minLength:4)
    Button {Task{await m.refresh()}} label:{Image(systemName:"arrow.clockwise")}.disabled(m.busy || m.binding == nil).help("刷新状态")
    Button {m.settings=true} label:{Image(systemName:"slider.horizontal.3")}.help("连接设置")
   }.buttonStyle(.plain)
  }
 }
 var setup: some View {
  VStack(alignment:.leading,spacing:18) {
   HStack { Text("连接你的空调").font(.system(size:22,weight:.semibold));Spacer();Button {m.settings=false} label:{Image(systemName:"xmark")}.buttonStyle(.plain).disabled(m.pairing) }
   Text("手机确认一次，以后从菜单栏轻松控制。\n设备密钥仅保存在此 Mac 的钥匙串中。").font(.system(size:12)).foregroundStyle(muted)
   Picker("米家地区",selection:$m.region) { ForEach([("cn","中国大陆"),("tw","中国台湾"),("sg","新加坡"),("de","欧洲"),("us","美国"),("ru","俄罗斯"),("in","印度"),("i2","印度二区")],id:\.0){key,name in Text(name).tag(key)} }.pickerStyle(.menu).disabled(m.pairing)
    .onChange(of:m.region) { _,_ in m.candidates = []; m.message = "地区已切换，请重新扫码登录" }
   Text("请选择与米家 App 相同的地区；可取消扫码后切换。").font(.caption).foregroundStyle(muted)
   if m.pairing {
    Group {
     if let qr=m.qr { Image(nsImage:qr).resizable().interpolation(.none).scaledToFit() }
     else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
    }.frame(width:190,height:190).padding(10).background(m.qr == nil ? Color.white.opacity(0.04):.white,in:RoundedRectangle(cornerRadius:12)).frame(maxWidth:.infinity)
   }
   Text(m.message).font(.system(size:12)).foregroundStyle(cream).fixedSize(horizontal:false,vertical:true)
   if m.pairing {Button("取消扫码") {m.cancelPair()}} else {Button("用米家 App 扫码绑定") {m.pair()}.buttonStyle(.borderedProminent).tint(cream).foregroundStyle(.black).disabled(m.busy)}
   ForEach(m.candidates) {d in Button {m.choose(d)} label:{HStack{VStack(alignment:.leading){Text(d.name ?? "米家空调");Text(d.supported ? "点击连接":"该型号暂不支持").font(.caption).foregroundStyle(muted)};Spacer();Image(systemName:d.supported ? "chevron.right":"minus.circle")}.padding(10)}.disabled(!d.supported || m.busy)}
   if m.binding != nil {
    Divider();Text("连接地址").font(.caption).foregroundStyle(muted)
    HStack {TextField("空调 IP",text:$m.address);Button("验证并保存") {m.updateAddress()}.disabled(m.busy || m.pairing)}
    Text("地址变化时可重新扫码，或填写米家中的最新 IP。").font(.caption).foregroundStyle(muted)
   }
   Divider();HStack {Text("Mi Air · 0.1").font(.caption).foregroundStyle(muted);Spacer();Button("退出应用"){NSApplication.shared.terminate(nil)}}
  }.textFieldStyle(.roundedBorder)
 }
 func roundButton(_ icon:String,_ title:String,action:@escaping()->Void)->some View {Button(action:action){Image(systemName:icon).font(.system(size:17)).frame(width:34,height:38).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:12))}.buttonStyle(PressStyle()).disabled(!m.online || m.busy).accessibilityLabel(title)}
 func mode(_ v:Int)->String { [2:"制冷",3:"除湿",4:"送风",5:"制热"][v] ?? "未知" }
 func format(_ v:Double)->String { v == v.rounded() ? String(format:"%.0f",v):String(format:"%.1f",v) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
 var item: NSStatusItem!; let popover=NSPopover(); var model: Model!; var poll: Task<Void,Never>?
 func applicationDidFinishLaunching(_ note:Notification) {
  if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
   let renderer = ImageRenderer(content: Panel(m: Model(preview: true)))
   renderer.scale = 2
   if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
   }
   NSApp.terminate(nil); return
  }
  let preview=CommandLine.arguments.contains("--preview")
  model=Model(preview:preview)
  item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
  item.button?.image=NSImage(systemSymbolName:"air.conditioner.horizontal",accessibilityDescription:"米家空调")
  item.button?.imagePosition = .imageLeading;item.button?.target=self;item.button?.action=#selector(toggle)
  model.panelHeight = min(560, max(360, (NSScreen.main?.visibleFrame.height ?? 800)-40))
  popover.behavior = .transient
  let host = NSHostingController(rootView:Panel(m:model))
  host.sizingOptions = []
  popover.contentViewController = host
  popover.contentSize = NSSize(width:430,height:model.panelHeight)
  model.onState = { [weak self] in self?.updateTitle() };updateTitle()
  if !preview {poll=Task {while !Task.isCancelled {await model.refresh();try? await Task.sleep(for:.seconds(15))}}}
  if CommandLine.arguments.contains("--setup") { model.settings = true }
  if CommandLine.arguments.contains("--pair") { model.settings = true; model.pair() }
  if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--pair") || CommandLine.arguments.contains("--setup") || preview { toggle() }
 }
 func updateTitle(){item.button?.title = model.online ? model.state?.room.map{String(format:" %.0f°",$0)} ?? "" : ""}
 @objc func toggle(){if popover.isShown{popover.performClose(nil)}else if let button=item.button{popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);NSApp.activate(ignoringOtherApps:true)}}
 func applicationWillTerminate(_ n:Notification){poll?.cancel();model?.cancelPair()}
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate=AppDelegate();app.delegate=delegate;app.run()
