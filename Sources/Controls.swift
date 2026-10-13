import SwiftUI

struct PressStyle: ButtonStyle {
 @Environment(\.accessibilityReduceMotion) private var reduced
 func makeBody(configuration: Configuration) -> some View {
  configuration.label.contentShape(Rectangle()).scaleEffect(reduced ? 1 : configuration.isPressed ? 0.97 : 1)
   .opacity(configuration.isPressed ? 0.72 : 1)
   .animation(reduced ? nil : .spring(response:0.16,dampingFraction:0.9),value:configuration.isPressed)
 }
}
struct OptionTile: View {
 let icon: String; let title: String; let value: String; let choices: [(Int,String)]; let choose: (Int)->Void
 @State private var open = false
 @State private var hover = false
 @Environment(\.accessibilityReduceMotion) private var reduced
 var body: some View {
  Button {open.toggle()} label: {
   VStack(alignment:.leading,spacing:7) {
    HStack { Image(systemName:icon).font(.system(size:20,weight:.light)); Spacer(); Image(systemName:"chevron.down").font(.system(size:8)).rotationEffect(.degrees(open ? 180:0)) }.foregroundStyle(muted)
    Text(title).font(.system(size:10)).foregroundStyle(muted)
    Text(value).font(.system(size:13,weight:.medium)).contentTransition(.opacity)
   }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(hover ? 0.085:0.045),in:RoundedRectangle(cornerRadius:10))
  }.buttonStyle(PressStyle()).onHover {hover=$0}.animation(reduced ? nil:.easeOut(duration:0.12),value:hover)
   .popover(isPresented:$open,arrowEdge:.bottom) {
    VStack(alignment:.leading,spacing:4) { ForEach(choices,id:\.0) {key,label in
     Button {open=false;choose(key)} label:{HStack {Text(label);Spacer();if label == value {Image(systemName:"checkmark")}}.padding(.horizontal,10).padding(.vertical,6).contentShape(Rectangle())}.buttonStyle(PressStyle())
    }}.padding(6).frame(width:126).preferredColorScheme(.dark)
   }.accessibilityLabel(title).accessibilityValue(value)
 }
}
struct TemperatureTrack: View {
 @Binding var value: Double; @Binding var editing: Bool; var commit: ()->Void
 @Environment(\.isEnabled) private var enabled
 @Environment(\.accessibilityReduceMotion) private var reduced
 var body: some View {
  GeometryReader { geo in
   let width = max(1,geo.size.width-24)
   ZStack(alignment:.leading) {
    RoundedRectangle(cornerRadius:12).fill(Color.white.opacity(0.045))
    RoundedRectangle(cornerRadius:12).fill(LinearGradient(colors:[cream.opacity(0.26),cream.opacity(0.10)],startPoint:.leading,endPoint:.trailing)).frame(width:24+width*(value-16)/15)
    RoundedRectangle(cornerRadius:8).fill(cream).frame(width:22,height:editing ? 34:30).shadow(color:cream.opacity(editing ? 0.15:0),radius:7).offset(x:1+width*(value-16)/15)
   }.frame(height:38).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {g in
    guard enabled else {return};editing=true;value=(min(31,max(16,16+Double((g.location.x-12)/width)*15))*2).rounded()/2
   }.onEnded {_ in guard enabled else{return};editing=false;commit()})
  }.frame(height:38).opacity(enabled ? 1:0.4).accessibilityElement().accessibilityLabel("设定温度").accessibilityValue("\(value) 摄氏度")
   .accessibilityAdjustableAction {direction in guard enabled else{return};switch direction {case .increment:value=min(31,value+0.5);case .decrement:value=max(16,value-0.5);@unknown default:return};commit()}
   .focusable(enabled).onKeyPress(.leftArrow) {guard enabled else{return .ignored};value=max(16,value-0.5);commit();return .handled}
   .onKeyPress(.rightArrow) {guard enabled else{return .ignored};value=min(31,value+0.5);commit();return .handled}
 }
}
