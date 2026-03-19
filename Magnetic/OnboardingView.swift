//
//  OnboardingView.swift
//  Magnetic
//
//  First-launch splash — tap anywhere to start
//

import SwiftUI

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
        .onTapGesture {
            onComplete()
        }
    }
}
