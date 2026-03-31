//
//  OnboardingView.swift
//  Magnetic
//
//  First-launch splash — tap anywhere to start
//

import SwiftUI

#if os(macOS)
/// Dismisses a sheet when the user clicks outside it (on the parent window)
struct SheetOutsideClickDismiss: ViewModifier {
    var onDismiss: () -> Void
    @State private var monitor: Any?
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    // If click is on the parent window behind the sheet, dismiss
                    if let eventWindow = event.window,
                       eventWindow.isSheet == false {
                        DispatchQueue.main.async { onDismiss() }
                    }
                    return event
                }
            }
            .onDisappear {
                if let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
            }
    }
}
#endif

struct OnboardingView: View {
    
    var onComplete: () -> Void
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            Text("MAGNETIC.")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onComplete()
        }
        #if os(macOS)
        .modifier(SheetOutsideClickDismiss(onDismiss: onComplete))
        #endif
    }
}
