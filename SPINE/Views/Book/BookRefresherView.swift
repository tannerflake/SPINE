//
//  BookRefresherView.swift
//  Spine
//
//  AI refresher sheet for a book the user has already read: generates a recap
//  (plot, key concepts, characters, takeaways, memorable moments) on open, then
//  lets the reader ask follow-up questions in a chat thread underneath.
//

import SwiftUI

struct BookRefresherView: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss

    @State private var refresher: BookRefresher?
    @State private var isGenerating = false
    @State private var generationFailed = false
    @State private var chatTurns: [RefresherChatTurn] = []
    @State private var question = ""
    @State private var isAnswering = false
    @FocusState private var questionFocused: Bool

    private var canAsk: Bool {
        refresher != nil && !isAnswering && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if isGenerating {
                            generatingState
                        } else if let r = refresher {
                            refresherSections(r)
                            chatSection
                        } else if generationFailed {
                            failedState
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("refresher-bottom")
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
                .background(Theme.background)
                .onChange(of: chatTurns.count) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("refresher-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: questionFocused) {
                    guard questionFocused else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("refresher-bottom", anchor: .bottom)
                        }
                    }
                }
            }

            if refresher != nil {
                questionInputRow
                    .background(
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(Theme.chrome.opacity(0.35))
                                .frame(height: Theme.chromeHairline)
                            Theme.background
                        }
                    )
            }
        }
        .background(Theme.background)
        .task(id: book.id) {
            chatTurns = BookRefresherService.shared.cachedChat(for: book)
            await generate()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI REFRESHER")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Theme.chrome)
                Text(book.title)
                    .font(Theme.headline())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close refresher")
        }
        .padding(.horizontal)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(
            VStack(spacing: 0) {
                Theme.background
                Rectangle()
                    .fill(Theme.chrome.opacity(0.35))
                    .frame(height: Theme.chromeHairline)
            }
        )
    }

    // MARK: - Loading / failed

    private var generatingState: some View {
        VStack(spacing: 16) {
            BookCoverView(book: book, size: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: Theme.shadowInk.opacity(0.18), radius: 10, x: 0, y: 5)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.chrome)
                Text("refreshing your memory…")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("Recapping the key ideas, plot, characters, takeaways, etc.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var failedState: some View {
        VStack(spacing: 14) {
            Text("Couldn't generate a refresher right now.")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await generate() }
            } label: {
                Text("Retry")
            }
            .buttonStyle(.spine(.primary, size: .regular, fullWidth: false))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Refresher sections

    @ViewBuilder
    private func refresherSections(_ r: BookRefresher) -> some View {
        Text(markdown: r.plot)
            .font(Theme.body())
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(Theme.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .hingeSectionCard(title: "The Story")

        if !r.keyConcepts.isEmpty {
            bulletList(r.keyConcepts, bulletColor: Theme.chrome)
                .hingeSectionCard(title: "Key Concepts")
        }

        if !r.characters.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(r.characters) { character in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(character.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(markdown: character.detail)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .hingeSectionCard(title: "Characters", accent: Theme.chromeStrong)
        }

        if !r.takeaways.isEmpty {
            bulletList(r.takeaways, bulletColor: Theme.accent)
                .hingeSectionCard(title: "Takeaways", accent: Theme.accent)
        }

        if !r.memorableMoments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(r.memorableMoments, id: \.self) { moment in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.punch.opacity(0.7))
                            .frame(width: 3)
                        Text(markdown: moment)
                            .font(Theme.body())
                            .italic()
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(Theme.bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .hingeSectionCard(title: "Memorable Moments", accent: Theme.punch)
        }
    }

    private func bulletList(_ items: [String], bulletColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(bulletColor)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(markdown: item)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Q&A chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if chatTurns.isEmpty {
                Text("Fuzzy on a detail? Ask anything: why a character did something, how a thread resolved, what a concept meant.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(chatTurns) { turn in
                    chatBubble(turn)
                }
            }
            if isAnswering {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.chrome)
                    Text("thinking…")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .hingeSectionCard(title: "Ask a Follow-up")
    }

    @ViewBuilder
    private func chatBubble(_ turn: RefresherChatTurn) -> some View {
        if turn.role == .user {
            Text(turn.text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.onChrome)
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.chrome)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        } else {
            Text(markdown: turn.text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Theme.chrome.opacity(0.25), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
        }
    }

    private var questionInputRow: some View {
        HStack(spacing: 10) {
            TextField("> ask about the book…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
                .focused($questionFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.chrome.opacity(0.4), lineWidth: 1)
                )
                .lineLimit(1...4)
            Button {
                askQuestion()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canAsk ? Theme.accent : Theme.textTertiary)
            }
            .disabled(!canAsk)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func generate() async {
        guard refresher == nil, !isGenerating else { return }
        if let cached = BookRefresherService.shared.cachedRefresher(for: book) {
            refresher = cached
            return
        }
        isGenerating = true
        generationFailed = false
        do {
            refresher = try await BookRefresherService.shared.refresher(for: book)
        } catch {
            generationFailed = true
        }
        isGenerating = false
    }

    private func askQuestion() {
        guard canAsk, let r = refresher else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        question = ""
        let priorTurns = chatTurns
        chatTurns.append(RefresherChatTurn(role: .user, text: asked))
        isAnswering = true
        Task {
            do {
                let reply = try await BookRefresherService.shared.answer(
                    question: asked,
                    for: book,
                    refresher: r,
                    history: priorTurns
                )
                await MainActor.run {
                    chatTurns.append(RefresherChatTurn(role: .assistant, text: reply))
                    BookRefresherService.shared.saveChat(chatTurns, for: book)
                    isAnswering = false
                }
            } catch {
                await MainActor.run {
                    // Put the question back so a retry is one tap away.
                    chatTurns = priorTurns
                    question = asked
                    isAnswering = false
                    ToastCenter.shared.show(
                        Toast(style: .error, status: "Failed", message: "Couldn't get an answer, try again")
                    )
                }
            }
        }
    }
}
