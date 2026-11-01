//
//  ContactConnectionView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 24/04/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct ContactConnectionView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        ChatPreviewView(chat: chat, progressByTimeout: Binding.constant(false))
    }
}

struct ContactConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        var contactConnection = PendingContactConnection.getSampleData()
        contactConnection.updatedAt = previewDate
        return ContactConnectionView(chat: Chat(chatInfo: .contactConnection(contactConnection: contactConnection)))
            .previewLayout(.fixed(width: 360, height: 80))
    }
}
