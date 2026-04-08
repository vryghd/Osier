//
//  ContentView.swift
//  Osier
//
//  Root entry point — delegates entirely to RootView.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        RootView()
    }
}

#Preview {
    ContentView()
        .environmentObject(LLMCoordinator.shared)
        .environmentObject(SafetyProtocolEngine())
        .environmentObject(PhotoKitManager.shared)
        .environmentObject(EventKitManager.shared)
}
