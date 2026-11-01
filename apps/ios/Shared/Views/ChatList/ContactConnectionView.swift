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
    @EnvironmentObject var m: ChatModel
    @ObservedObject var chat: Chat
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var userFont: DynamicTypeSize
    @State private var localAlias = ""
    @FocusState private var aliasTextFieldFocused: Bool

    var body: some View {
        if case let .contactConnection(conn) = chat.chatInfo {
            contactConnectionView(conn)
        }
    }

    func contactConnectionView(_ contactConnection: PendingContactConnection) -> some View {
        let size = dynamicSize(userFont)
        return HStack(spacing: 8) {
            Group {
                Image(systemName: contactConnection.initiated ? "link.badge.plus" : "link")
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.profileImageSize * 48 / 63, height: size.profileImageSize * 48 / 63)
                    .foregroundColor(Color(uiColor: .tertiarySystemGroupedBackground).asAnotherColorFromSecondaryVariant(theme))
            }
            .frame(width: size.profileImageSize, height: size.profileImageSize)
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(contactConnection.chatViewName)
                        .font(.title3)
                        .bold()
                        .allowsTightening(false)
                        .foregroundColor(theme.colors.secondary)
                        .lineLimit(1)
                        .frame(alignment: .topLeading)

                    Spacer()

                    formatTimestampText(contactConnection.updatedAt)
                        .font(.subheadline)
                        .padding(.top, 4)
                        .frame(minWidth: 60, alignment: .trailing)
                        .foregroundColor(theme.colors.secondary)
                }
                .padding(.bottom, 4)
                .padding(.horizontal, 8)

                ZStack(alignment: .topTrailing) {
                    Text(contactConnection.description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                        .padding(.trailing, 36)
                    incognitoIcon(contactConnection.incognito, theme.colors.secondary, size: size.incognitoSize)
                        .padding(.top, size.chatInfoSize * 1.44)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.trailing, 8)

                Spacer()
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, -8)
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
