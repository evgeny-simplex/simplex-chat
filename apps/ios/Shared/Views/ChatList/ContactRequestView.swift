//
//  ContactRequestView.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 02/02/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct ContactRequestView: View {
    @ObservedObject var chat: Chat

    var body: some View {
        ChatPreviewView(chat: chat, progressByTimeout: Binding.constant(false))
    }
}

struct ContactRequestView_Previews: PreviewProvider {
    static var previews: some View {
        var contactRequest = UserContactRequest.sampleData
        contactRequest.updatedAt = previewDate
        return ContactRequestView(chat: Chat(chatInfo: .contactRequest(contactRequest: contactRequest), chatItems: []))
            .previewLayout(.fixed(width: 360, height: 80))
    }
}
